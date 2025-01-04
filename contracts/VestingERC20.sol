// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";

/**
 * @title VestingERC20Multi
 * @notice Example contract that:
 *   - Creates a NEW vesting schedule every time tokens are transferred (to the recipient).
 *   - 50% is immediately vested, 50% withheld and vests over 7 days (linear).
 *   - If sender tries to transfer more tokens than their vested amount, the difference is forfeited into a global pool.
 *   - Fully-vested addresses earn a share of the forfeited pool via daily compounding (1%).
 *   - FIFO approach to forfeiting withheld amounts.
 *   - Cleans up old schedules for both parties to reduce storage usage.
 */
contract VestingERC20 is ERC20, Ownable, ReentrancyGuard, Pausable {
    using Math for uint256;

    // -------------------------
    // Events
    // -------------------------
    event Forfeited(address indexed from, uint256 amount);
    event Claimed(address indexed user, uint256 forfeitedAmount);
    event VestingStarted(address indexed user, uint256 amount);
    event VestingMerged(
        address indexed user,
        uint256 amount,
        uint256 scheduleIndex
    );
    event VestingSchedulesCleaned(
        address indexed user,
        uint256 schedulesRemoved
    );
    event ExemptionStatusUpdated(address indexed account, bool isExempt);

    // -------------------------
    // Custom Errors
    // -------------------------
    error NothingToClaim();
    error NotAuthorized();
    error ZeroAddress();
    error InvalidAddress();
    error InsufficientBalance(uint256 requested, uint256 available);

    // -------------------------
    // Constants
    // -------------------------
    uint256 public constant INITIAL_SUPPLY = 1_000_000_000;
    uint256 public constant VESTING_DURATION = 7 days;
    uint256 public constant MERGE_WINDOW = 1 days;
    uint256 public constant MAX_SCHEDULES = 50;
    uint256 public constant SCALE = 1e18;
    // 1% daily growth => 1.01 * 1e18
    uint256 public constant DAILY_RATE = 1_01e18;
    // Precompute 1 / 7 days in 1e18 form for any linear vest calcs
    uint256 public constant VESTING_DURATION_INV = 1e18 / VESTING_DURATION;

    // -------------------------
    // Structs & Storage
    // -------------------------
    struct VestingInfo {
        // The original amount of tokens for this schedule
        // (50% withheld, 50% immediate)
        uint256 initialBalance;
        // The portion that will vest linearly over 7 days
        uint256 withheldAmount;
        // Start & end of vest
        uint256 vestStart;
        uint256 vestComplete;
        // True once time >= vestComplete
        bool fullyVested;
        // For daily compounding after fully vested (starts at 0, set to 1e18 upon full vest)
        uint256 multiple;
        // The last timestamp we applied the daily increment
        uint256 lastMultipleUpdate;
        // How many forfeited tokens have been claimed from this schedule
        uint256 claimedForfeits;
        // The last timestamp we applied the daily increment
        uint256 lastDepositTime;
    }

    /**
     * @dev Each user can accumulate many schedules (one per incoming transfer).
     */
    mapping(address => VestingInfo[]) public vestSchedules;

    // Running pool of forfeited tokens
    uint256 public forfeitedPool;

    /**
     * @dev Weighted contributions = sum of (schedule.multiple * schedule.initialBalance / 1e18)
     *      for all *fully vested* schedules of a user. Used to pro-rate the forfeitedPool.
     */
    mapping(address => uint256) public userWeightedContribution;
    uint256 public totalWeightedContributions;

    // Treasury address
    address public treasury;

    /**
     * @notice Mapping to store whitelisted addresses that are exempt from vesting (DEXs).
     */
    mapping(address => bool) public isExemptFromVesting;

    // -------------------------
    // Constructor
    // -------------------------
    constructor(
        string memory name,
        string memory symbol,
        address _treasury
    ) ERC20(name, symbol) Ownable(msg.sender) ReentrancyGuard() {
        _mint(_treasury, INITIAL_SUPPLY * 10 ** decimals());
        treasury = _treasury;
    }

    // -------------------------
    // External (User) Functions
    // -------------------------
    /**
     * @notice Claim user's share of the forfeited pool across all fully-vested schedules.
     */
    function claim() external nonReentrant {
        _updateAllVestingStates(msg.sender);

        uint256 claimable = getClaimable(msg.sender);
        if (claimable == 0) revert NothingToClaim();

        // Reduce our internal record of forfeited pool
        forfeitedPool -= claimable;

        // Record that these forfeits are now claimed
        _recordClaimForfeits(msg.sender, claimable);

        // Transfer from the contract to the user
        _transfer(address(treasury), msg.sender, claimable);

        emit Claimed(msg.sender, claimable);
    }

    // -------------------------
    // ERC20 Overrides
    // -------------------------
    /**
     * @notice On *every* transfer, the `to` address automatically gets a new vesting schedule
     *         for the `amount` they receive.
     *         The sender may forfeit any unvested portion if `amount` exceeds their vested balance.
     */
    function transfer(
        address to,
        uint256 amount
    ) public virtual override whenNotPaused nonReentrant returns (bool) {
        _transferWithVesting(_msgSender(), to, amount);
        return true;
    }

    function transferFrom(
        address from,
        address to,
        uint256 amount
    ) public virtual override whenNotPaused nonReentrant returns (bool) {
        address spender = _msgSender();
        _spendAllowance(from, spender, amount);

        _transferWithVesting(from, to, amount);
        return true;
    }

    // -------------------------
    // Owner Functions
    // -------------------------
    /**
     * @notice Toggle exemption status for DEX/MM addresses
     * @param account Address to update
     * @param exempt True to exempt from vesting, false to remove exemption
     */
    function setVestingExemption(
        address account,
        bool exempt
    ) external onlyOwner {
        if (account == address(0)) revert InvalidAddress();
        isExemptFromVesting[account] = exempt;
        emit ExemptionStatusUpdated(account, exempt);
    }

    // -------------------------
    // Public / View Functions
    // -------------------------
    /**
     * @notice Returns how many forfeited tokens `user` can currently claim.
     */
    function getClaimable(address user) public view returns (uint256) {
        if (totalWeightedContributions == 0) {
            return 0;
        }

        uint256 userShare = 0;
        VestingInfo[] memory schedules = vestSchedules[user];
        for (uint256 i = 0; i < schedules.length; i++) {
            VestingInfo memory info = schedules[i];
            if (info.fullyVested) {
                // Weighted portion
                uint256 scheduleWeighted = (info.multiple *
                    info.initialBalance) / SCALE;
                uint256 scheduleShare = (scheduleWeighted * forfeitedPool) /
                    totalWeightedContributions;

                if (scheduleShare > info.claimedForfeits) {
                    userShare += (scheduleShare - info.claimedForfeits);
                }
            }
        }
        return userShare;
    }

    /**
     * @notice Returns how many tokens are currently vested across *all* schedules for `user`.
     *         If the user doesn't have any schedules, everything is effectively vested.
     */
    function getVestedBalance(address user) external view returns (uint256) {
        return _getVestedBalance(user);
    }

    /**
     * @notice An example aggregator function that sums up the user’s total vested,
     *         unvested, and time to next vest completion.
     */
    function getVestingProgress(
        address user
    )
        external
        view
        returns (
            uint256 totalVested,
            uint256 totalUnvested,
            uint256 nextVestCompletion
        )
    {
        VestingInfo[] memory schedules = vestSchedules[user];
        if (schedules.length == 0) {
            // No schedules => all tokens are effectively vested
            return (balanceOf(user), 0, 0);
        }

        uint256 vestedSum = 0;
        uint256 earliestVestComplete = type(uint256).max;

        for (uint256 i = 0; i < schedules.length; i++) {
            VestingInfo memory info = schedules[i];
            vestedSum += _computeScheduleVested(info);

            if (!info.fullyVested && info.vestComplete < earliestVestComplete) {
                earliestVestComplete = info.vestComplete;
            }
        }

        uint256 actualBalance = balanceOf(user);
        if (vestedSum > actualBalance) {
            vestedSum = actualBalance;
        }

        totalVested = vestedSum;
        totalUnvested = (actualBalance > vestedSum)
            ? (actualBalance - vestedSum)
            : 0;

        nextVestCompletion = (earliestVestComplete == type(uint256).max)
            ? 0
            : (
                block.timestamp >= earliestVestComplete
                    ? 0
                    : earliestVestComplete - block.timestamp
            );
    }

    // -------------------------
    // Internal Functions
    // -------------------------

    /**
     * @dev Core logic for transferring with vesting:
     *      1) Update sender & recipient vest states
     *      2) Forfeit any unvested portion if transferring more than sender's vested
     *      3) Perform the ERC20 transfer
     *      4) Create a NEW vesting schedule for the recipient for the full `amount`
     */
    function _transferWithVesting(
        address from,
        address to,
        uint256 amount
    ) internal {
        if (to == address(0)) revert ZeroAddress();

        // Case 1: Transfer between exempt addresses (DEX-to-DEX)
        if (isExemptFromVesting[from] && isExemptFromVesting[to]) {
            _transfer(from, to, amount);
            return;
        }

        // Compute how many tokens the sender actually has vested
        uint256 vestedBal = _getVestedBalance(from);
        // Compute how many tokens are unvested
        uint256 unvested = (amount > vestedBal) ? (amount - vestedBal) : 0;

        // Case 2: Transfer TO exempt (user selling to DEX)
        if (isExemptFromVesting[to]) {
            _updateAllVestingStates(from);

            if (unvested > 0) {
                // Move unvested portion into the contract's balance
                _transfer(from, address(treasury), unvested);
                forfeitedPool += unvested;

                // Remove unvested portion from user’s vesting schedules
                _forfeitFromSchedules(from, unvested);
                emit Forfeited(from, unvested);
                amount = vestedBal;
            }

            _transfer(from, to, amount);
            return;
        }

        // CASE 3: Transfer FROM an exempt address (user buying from DEX)
        if (isExemptFromVesting[from]) {
            _updateAllVestingStates(to);
            _transfer(from, to, amount);

            // create vesting schedule for the recipient
            _createOrMergeVestingSchedule(to, amount);
            return;
        }

        // CASE 4: Normal P2P transfer with vesting logic on both sides
        _updateAllVestingStates(from);
        _updateAllVestingStates(to);

        if (unvested > 0) {
            // Move unvested portion into the contract's balance
            _transfer(from, address(treasury), unvested);
            forfeitedPool += unvested;

            // Remove unvested portion from user’s schedules
            _forfeitFromSchedules(from, unvested);
            emit Forfeited(from, unvested);
            amount = vestedBal;
        }

        // Do the actual transfer of vested amount
        _transfer(from, to, amount);

        // create vesting schedule for the recipient
        if (amount > 0) {
            _createOrMergeVestingSchedule(to, amount);
        }
    }

    /**
     * @dev Merges a new deposit into an existing vesting schedule or creates a new one.
     */
    function _createOrMergeVestingSchedule(
        address user,
        uint256 amount
    ) internal {
        // First cleanup any completed schedules
        _cleanupVestingSchedules(user);

        VestingInfo[] storage schedules = vestSchedules[user];

        // If too many schedules, force merge with oldest non-full schedule
        if (schedules.length >= MAX_SCHEDULES) {
            _forceScheduleMerge(user, amount);
            return;
        }

        // Try to find a schedule that's within our merge window
        for (uint256 i = 0; i < schedules.length; i++) {
            VestingInfo storage schedule = schedules[i];

            // Only merge into non-fully-vested schedules within the merge window
            if (
                !schedule.fullyVested &&
                block.timestamp <= schedule.lastDepositTime + MERGE_WINDOW
            ) {
                // Merge the amounts
                uint256 newWithheld = amount / 2;
                schedule.initialBalance += amount;
                schedule.withheldAmount += newWithheld;
                schedule.lastDepositTime = block.timestamp;

                // Don't extend the vesting end time - keep original
                emit VestingMerged(user, amount, i);
                return;
            }
        }

        // If no suitable schedule found, create new one
        _createVestingSchedule(user, amount);
    }

    /**
     * @dev Creates a new 7-day vesting schedule for `user`.
     *      50% immediate, 50% withheld vesting linearly over 7 days.
     */
    function _createVestingSchedule(address user, uint256 amount) internal {
        VestingInfo memory newSchedule;
        newSchedule.initialBalance = amount;
        newSchedule.withheldAmount = amount / 2;
        newSchedule.vestStart = block.timestamp;
        newSchedule.vestComplete = block.timestamp + VESTING_DURATION;
        newSchedule.fullyVested = false;
        newSchedule.multiple = 0;
        newSchedule.lastMultipleUpdate = block.timestamp;
        newSchedule.claimedForfeits = 0;
        newSchedule.lastDepositTime = block.timestamp; // Added this line

        vestSchedules[user].push(newSchedule);
        emit VestingStarted(user, amount);
    }

    /**
     * @dev Iterates over all schedules, updating which ones are fully vested
     *      and applying daily compounding if so. Then recalculates user’s
     *      total weighted contribution.
     */
    function _updateAllVestingStates(address user) internal {
        VestingInfo[] storage schedules = vestSchedules[user];
        if (schedules.length == 0) return;

        // Remove old weighting from global
        uint256 oldWeighted = userWeightedContribution[user];
        if (oldWeighted > 0) {
            totalWeightedContributions -= oldWeighted;
        }

        uint256 newWeightedSum = 0;

        for (uint256 i = 0; i < schedules.length; i++) {
            VestingInfo storage info = schedules[i];

            // If not fully vested, check if vestComplete time has passed
            if (!info.fullyVested && block.timestamp >= info.vestComplete) {
                info.fullyVested = true;
                info.multiple = SCALE; // 1.0
                info.lastMultipleUpdate = block.timestamp;
            }

            // If fully vested, apply daily increments
            if (info.fullyVested) {
                _applyDailyIncrement(info);
                // Weighted = (multiple * initialBalance) / 1e18
                uint256 scheduleWeighted = (info.multiple *
                    info.initialBalance) / SCALE;
                newWeightedSum += scheduleWeighted;
            }
        }

        // Update user weighting
        userWeightedContribution[user] = newWeightedSum;
        // Update global weighting
        totalWeightedContributions += newWeightedSum;
    }

    /**
     * @dev Deduct `toForfeit` from the user's withheld tokens in FIFO order
     *      until we've accounted for all unvested tokens that need forfeiting.
     */
    function _forfeitFromSchedules(address from, uint256 toForfeit) internal {
        VestingInfo[] storage schedules = vestSchedules[from];

        for (uint256 i = 0; i < schedules.length; i++) {
            if (toForfeit == 0) break;
            VestingInfo storage info = schedules[i];

            if (info.withheldAmount > 0) {
                uint256 amountHere = info.withheldAmount;
                uint256 forfeitAmount = (amountHere >= toForfeit)
                    ? toForfeit
                    : amountHere;

                info.withheldAmount -= forfeitAmount;
                toForfeit -= forfeitAmount;
            }
        }
        // TODO: come back to this
        // If `toForfeit` remains > 0 after the loop, it means
        // user is forfeiting more than all withheld amounts combined.
        // That generally shouldn't happen if logic is correct.
    }

    /**
     * @dev Apply daily increment using simplified interest calculation
     *      and OpenZeppelin's Math for safe operations
     */
    function _applyDailyIncrement(VestingInfo storage info) internal {
        uint256 daysPassed = (block.timestamp - info.lastMultipleUpdate) /
            1 days;
        if (daysPassed == 0) return;

        if (daysPassed > 365) daysPassed = 365;

        // Calculate total interest (days * 0.01)
        uint256 totalInterest = daysPassed * (DAILY_RATE - SCALE);

        // Growth factor is 1.0 + total interest
        uint256 growthFactor = SCALE + totalInterest;

        // Apply growth to current multiple using OpenZeppelin's Math
        info.multiple = Math.mulDiv(info.multiple, growthFactor, SCALE);
        info.lastMultipleUpdate += daysPassed * 1 days;
    }

    /**
     * @dev Sums how many tokens are vested right now across all of user's schedules.
     *      Compares that with user's actual on-chain balance, returning the min.
     */
    function _getVestedBalance(address user) internal view returns (uint256) {
        VestingInfo[] memory schedules = vestSchedules[user];
        if (schedules.length == 0) {
            // No schedules => all tokens are effectively vested
            return balanceOf(user);
        }

        uint256 vestedSum = 0;
        for (uint256 i = 0; i < schedules.length; i++) {
            vestedSum += _computeScheduleVested(schedules[i]);
        }

        uint256 actualBalance = balanceOf(user);
        return (vestedSum > actualBalance) ? actualBalance : vestedSum;
    }

    /**
     * @dev Computes how many tokens are vested in a single schedule at this moment.
     *      50% immediate, plus linear vesting of the withheld half over 7 days.
     */
    function _computeScheduleVested(
        VestingInfo memory info
    ) internal view returns (uint256) {
        if (info.fullyVested) {
            return info.initialBalance;
        }

        uint256 immediate = info.initialBalance / 2;
        uint256 timePassed = (block.timestamp > info.vestComplete)
            ? VESTING_DURATION
            : (block.timestamp - info.vestStart);

        // linear fraction of withheld
        uint256 vestedWithheld = (info.withheldAmount * timePassed) /
            VESTING_DURATION;
        return immediate + vestedWithheld;
    }

    /**
     * @dev After we compute how much a user can claim, we distribute that claim
     *      across the user's fully-vested schedules, proportionally to their weighted share.
     *      Then cleanup any schedules that have claimed all their forfeits.
     */
    function _recordClaimForfeits(address user, uint256 totalToClaim) internal {
        VestingInfo[] storage schedules = vestSchedules[user];

        // 1) sum up total weighting across fully vested schedules
        uint256 totalUserWeighted = 0;
        for (uint256 i = 0; i < schedules.length; i++) {
            VestingInfo storage info = schedules[i];
            if (info.fullyVested) {
                uint256 scheduleWeighted = (info.multiple *
                    info.initialBalance) / SCALE;
                totalUserWeighted += scheduleWeighted;
            }
        }

        if (totalUserWeighted == 0) {
            // should not happen if claimable > 0, but just in case
            return;
        }

        // 2) distribute totalToClaim proportionally
        uint256 remaining = totalToClaim;
        for (uint256 i = 0; i < schedules.length; i++) {
            if (remaining == 0) break;
            VestingInfo storage info = schedules[i];

            if (info.fullyVested) {
                uint256 scheduleWeighted = (info.multiple *
                    info.initialBalance) / SCALE;
                uint256 claimShare = (scheduleWeighted * totalToClaim) /
                    totalUserWeighted;
                if (claimShare > remaining) {
                    claimShare = remaining;
                }

                info.claimedForfeits += claimShare;
                remaining -= claimShare;
            }
        }

        // 3) Cleanup any schedules that have claimed all their forfeits
        _cleanupVestingSchedules(user);
    }

    /**
     * @dev Forces merging of new amount into an existing schedule when user has too many schedules.
     * Priority for merging:
     * 1. First non-fully vested schedule
     * 2. If all are vested, merge with newest schedule
     * @param user Address of the user receiving tokens
     * @param amount Amount of tokens to add to a schedule
     */
    function _forceScheduleMerge(address user, uint256 amount) internal {
        // First try to clean up any old schedules
        _cleanupVestingSchedules(user);

        VestingInfo[] storage schedules = vestSchedules[user];
        require(schedules.length > 0, "No schedules to merge with");

        // Try to find first non-fully vested schedule
        for (uint256 i = 0; i < schedules.length; i++) {
            VestingInfo storage schedule = schedules[i];

            if (!schedule.fullyVested) {
                // Calculate remaining vesting duration
                uint256 remainingTime = 0;
                if (block.timestamp < schedule.vestComplete) {
                    remainingTime = schedule.vestComplete - block.timestamp;
                }

                // Add new amounts
                uint256 newWithheld = amount / 2;
                schedule.initialBalance += amount;
                schedule.withheldAmount += newWithheld;
                schedule.lastDepositTime = block.timestamp;

                // Extend vesting end time proportionally based on new amount
                if (remainingTime > 0) {
                    uint256 originalAmount = schedule.initialBalance - amount;
                    uint256 weightedDuration = (remainingTime *
                        amount +
                        VESTING_DURATION *
                        originalAmount) / (amount + originalAmount);
                    schedule.vestComplete = block.timestamp + weightedDuration;
                }

                emit VestingMerged(user, amount, i);
                return;
            }
        }

        // If all schedules are fully vested, merge with the newest one (last in array)
        VestingInfo storage newestSchedule = schedules[schedules.length - 1];

        // Since it's fully vested, we just need to add the amounts
        newestSchedule.initialBalance += amount;
        // The multiple stays the same since it's based on time vested
        // The lastMultipleUpdate stays the same to maintain compound interest schedule

        emit VestingMerged(user, amount, schedules.length - 1);
    }

    /**
     * @dev Cleans up vesting schedules for a user, removing fully vested schedules with no pending claims.
     */
    function _cleanupVestingSchedules(address user) internal {
        VestingInfo[] storage schedules = vestSchedules[user];
        uint256 initialLength = schedules.length;
        uint256 i = 0;
        while (i < schedules.length) {
            VestingInfo storage schedule = schedules[i];
            // Check if schedule is fully vested and has no pending claims
            if (
                schedule.fullyVested &&
                schedule.claimedForfeits >=
                (schedule.multiple * schedule.initialBalance * forfeitedPool) /
                    (totalWeightedContributions * SCALE)
            ) {
                // Remove by swapping with last element and popping
                schedules[i] = schedules[schedules.length - 1];
                schedules.pop();
            } else {
                i++;
            }
        }

        uint256 removed = initialLength - schedules.length;
        if (removed > 0) {
            emit VestingSchedulesCleaned(user, removed);
        }
    }
}
