// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import "hardhat/console.sol";

/**
 * @title VestingToken
 * @notice An ERC20 token with vesting mechanisms combining:
 *   1) On-chain vesting schedules for accurate forfeit calculations
 *   2) Efficient schedule merging to prevent storage bloat
 *   3) Off-chain aggregator + Merkle-based distribution for rewards
 *
 * Key Features:
 * - 50% of tokens locked on buy with 7-day linear vesting
 * - Forfeiture of unvested tokens on early sells
 * - Merging of schedules within 1 day window
 * - Protection against dust attacks via minimum vest amount
 * - One-time claiming of vested + bonus rewards via Merkle proof
 *
 * Off-chain Aggregator Requirements:
 * - Must track fully vested positions
 * - Calculate pro-rata share of forfeited tokens
 * - Include 1% daily bonus for long-term holders post full vest
 * - Generate Merkle root for periodic reward distributions
 *
 * Security Features:
 * - Reentrancy protection on claiming
 * - Minimum vest amount to prevent dust attacks
 * - Schedule capping to prevent storage attacks
 *
 * NOT AUDITED - Example implementation only
 */
contract VestingToken is ERC20, Ownable, ReentrancyGuard {
    // ----------------------------------
    // DATA: SCHEDULES, MERGING, DEX PAIRS
    // ----------------------------------
    struct VestingSchedule {
        uint256 totalLocked;
        uint256 released;
        uint256 startTime;
    }

    mapping(address => VestingSchedule[]) public schedules;
    mapping(address => bool) public dexPairs;

    // Merge schedules within 1 day
    uint256 public mergeWindow = 1 days;
    // Failsafe to prevent storage bloat
    uint256 public constant MAX_SCHEDULES = 30;
    // Minimum vest amount to prevent dust attacks
    uint256 public constant MIN_VEST_AMOUNT = 100;

    // ----------------------------------
    // VESTING / FORFEIT CONFIG
    // ----------------------------------
    uint256 public constant VESTING_DURATION = 7 days;
    uint256 public constant LOCK_PERCENTAGE = 50; // 50% locked at buy

    // ----------------------------------
    // MERKLE DISTRIBUTION CONFIG
    // ----------------------------------
    bytes32 public merkleRoot;
    mapping(address => bool) public hasClaimed;

    // ----------------------------------
    // EVENTS
    // ----------------------------------
    event DexPairUpdated(address indexed pair, bool status);
    event ScheduleMerged(address indexed user, uint256 idxA, uint256 idxB);
    event SchedulesForfeited(address indexed user, uint256 totalForfeited);
    event ScheduleAdded(
        address indexed user,
        uint256 lockedAmount,
        uint256 startTime
    );
    event Forfeited(address indexed user, uint256 amount);
    event MerkleRootUpdated(bytes32 oldRoot, bytes32 newRoot);
    event Claimed(address indexed user, uint256 amount);
    event MergeWindowUpdated(uint256 newWindow);
    event ScheduleUpdated(
        address indexed user,
        uint256 scheduleIndex,
        uint256 totalLocked,
        uint256 released,
        uint256 startTime
    );

    // ----------------------------------
    // ERRORS
    // ----------------------------------
    error TransferFromZeroAddress();
    error TransferToZeroAddress();
    error TransferAmountExceedsBalance();
    error AlreadyClaimed();
    error InvalidMerkleProof();
    error InsufficientContractBalance();
    error InvalidDexPair();

    // ----------------------------------
    // CONSTRUCTOR
    // ----------------------------------
    constructor(
        string memory name_,
        string memory symbol_,
        uint256 initialSupply,
        address treasury
    ) ERC20(name_, symbol_) Ownable(msg.sender) {
        _mint(treasury, initialSupply * 10 ** decimals());
    }

    // ----------------------------------
    // OWNER FUNCTIONS
    // ----------------------------------
    function setDexPair(address pair, bool _status) external onlyOwner {
        if (pair == address(0)) revert InvalidDexPair();
        dexPairs[pair] = _status;
        emit DexPairUpdated(pair, _status);
    }

    function setMerkleRoot(bytes32 _merkleRoot) external onlyOwner {
        emit MerkleRootUpdated(merkleRoot, _merkleRoot);
        merkleRoot = _merkleRoot;
    }

    function setMergeWindow(uint256 _mergeWindow) external onlyOwner {
        mergeWindow = _mergeWindow;
        emit MergeWindowUpdated(_mergeWindow);
    }

    // ----------------------------------
    // VIEW FUNCTIONS
    // ----------------------------------
    function getScheduleCount(address user) external view returns (uint256) {
        return schedules[user].length;
    }

    function getSchedule(
        address user,
        uint256 index
    ) external view returns (VestingSchedule memory) {
        return schedules[user][index];
    }

    function userTotalLocked(address user) external view returns (uint256) {
        VestingSchedule[] memory arr = schedules[user];
        uint256 total;
        for (uint256 i = 0; i < arr.length; i++) {
            VestingSchedule memory s = arr[i];
            // locked portion is s.totalLocked - s.released
            total += (s.totalLocked - s.released);
        }
        return total;
    }

    function userTotalUnvested(address user) external view returns (uint256) {
        uint256 locked = this.userTotalLocked(user);
        uint256 vested = this._calculateVested(user);
        // unvested = locked - vested
        return locked > vested ? locked - vested : 0;
    }

    function timeUntilFullyVested(
        address user
    ) external view returns (uint256) {
        VestingSchedule[] memory arr = schedules[user];
        if (arr.length == 0) return 0; // no schedules => nothing

        uint256 maxEndTime = 0;
        for (uint256 i = 0; i < arr.length; i++) {
            VestingSchedule memory s = arr[i];
            // each schedule ends at s.startTime + VESTING_DURATION
            uint256 endTime = s.startTime + VESTING_DURATION;
            if (endTime > maxEndTime) {
                maxEndTime = endTime;
            }
        }

        if (block.timestamp >= maxEndTime) {
            return 0; // fully vested
        } else {
            return maxEndTime - block.timestamp;
        }
    }

    function previewSellForfeit(
        address user,
        uint256 sellAmount
    ) external view returns (uint256) {
        return _calculateUnvested(user, sellAmount);
    }

    // ----------------------------------
    // ERC20 OVERRIDES
    // ----------------------------------
    function transfer(
        address to,
        uint256 amount
    ) public virtual override returns (bool) {
        _transferWithVesting(msg.sender, to, amount);
        return true;
    }

    function transferFrom(
        address from,
        address to,
        uint256 amount
    ) public virtual override returns (bool) {
        address spender = msg.sender;
        _spendAllowance(from, spender, amount);
        _transferWithVesting(from, to, amount);
        return true;
    }

    /**
     * @dev Main logic for buy/sell detection and on-chain forfeit
     */
    function _transferWithVesting(
        address from,
        address to,
        uint256 amount
    ) internal {
        if (from == address(0)) revert TransferFromZeroAddress();
        if (to == address(0)) revert TransferToZeroAddress();

        if (amount < MIN_VEST_AMOUNT) {
            _transfer(from, to, amount);
            return;
        }

        // 1) BUY (from is DEX pair)
        if (dexPairs[from]) {
            // Lock 50%
            uint256 locked = (amount * LOCK_PERCENTAGE) / 100;
            uint256 immediate = amount - locked;

            // immediate portion
            _transfer(from, to, immediate);

            // locked portion -> this contract
            if (locked > 0) {
                _transfer(from, address(this), locked);
                _addVestingSchedule(to, locked);
            }
            return;

            // 2) SELL (to is DEX pair)
        } else if (dexPairs[to]) {
            // Calculate how many tokens are unvested
            uint256 unvested = _calculateUnvested(from, amount);
            if (unvested > 0) {
                // Forfeit them
                _transfer(from, address(this), unvested);
                _updateUserVestState(from);
                _updateSchedulesOnForfeit(from, unvested);
                emit Forfeited(from, unvested);
                amount -= unvested;
            }
            _transfer(from, to, amount);
            return;
        }

        // 3) user->user
        _transfer(from, to, amount);
    }

    // ----------------------------------
    // SCHEDULE MANAGEMENT + MERGING
    // ----------------------------------
    /**
     * @dev Add a vesting schedule for a user
     * @param user The address of the user
     * @param lockedAmount The amount of tokens being locked
     */
    function _addVestingSchedule(address user, uint256 lockedAmount) internal {
        VestingSchedule[] storage arr = schedules[user];
        uint256 len = arr.length;

        // Check if there are any existing schedules
        if (len > 0) {
            // Get the most recent schedule
            VestingSchedule storage lastSched = arr[len - 1];

            // Check two conditions:
            // 1. Is this new vest happening within mergeWindow (1 day) of the last schedule?
            // 2. Is the last schedule still actively vesting
            if (
                (block.timestamp - lastSched.startTime) < mergeWindow &&
                !_isFullyVested(lastSched)
            ) {
                // Instead of creating a new schedule, add the amount to the existing one
                lastSched.totalLocked += lockedAmount;
                // Log the addition
                emit ScheduleUpdated(
                    user,
                    len - 1,
                    lastSched.totalLocked,
                    lastSched.released,
                    lastSched.startTime
                );
                return; // Exit early since we've handled the new amount
            }
        }

        VestingSchedule memory newSched = VestingSchedule({
            totalLocked: lockedAmount,
            released: 0,
            startTime: block.timestamp
        });
        arr.push(newSched);
        emit ScheduleUpdated(
            user,
            len,
            newSched.totalLocked,
            newSched.released,
            newSched.startTime
        );

        _mergeFullyVestedSchedules(user);
        if (arr.length > MAX_SCHEDULES) {
            _mergeOldestSchedules(user);
        }
    }

    /**
     * @dev Updates the user’s schedules so that `released` reflects
     *      any newly vested amount since the last update.
     */
    function _updateUserVestState(address user) internal {
        VestingSchedule[] storage arr = schedules[user];
        for (uint256 i = 0; i < arr.length; i++) {
            VestingSchedule storage sched = arr[i];
            // how many tokens remain locked in this schedule
            uint256 active = sched.totalLocked - sched.released;
            if (active == 0) continue;

            // partial linear vest since sched.startTime
            uint256 vestedSoFar = _calculateLinearVested(
                active,
                sched.startTime
            );
            // ensure we don’t exceed 'active'
            uint256 newlyVested = vestedSoFar > active ? active : vestedSoFar;

            // The difference between newlyVested and sched.released is how many tokens
            // just got vested since last check.
            uint256 increment = newlyVested - sched.released;
            if (increment > 0) {
                sched.released += increment;
            }
        }

        _mergeFullyVestedSchedules(user);
    }

    /**
     * @dev Actually forfeit `forfeitAmount` from the user's schedules,
     *      which is presumably some or all of their unvested portion.
     */
    function _updateSchedulesOnForfeit(
        address user,
        uint256 forfeitAmount
    ) internal {
        VestingSchedule[] storage userSchedules = schedules[user];
        uint256 remainingForfeit = forfeitAmount;

        for (
            uint256 i = userSchedules.length;
            i > 0 && remainingForfeit > 0;

        ) {
            i--;
            VestingSchedule storage schedule = userSchedules[i];

            // unvestedInSchedule = totalLocked - released
            uint256 unvestedInSchedule = schedule.totalLocked -
                schedule.released;
            if (unvestedInSchedule > 0) {
                uint256 forfeitFromSchedule = remainingForfeit >
                    unvestedInSchedule
                    ? unvestedInSchedule
                    : remainingForfeit;

                schedule.totalLocked -= forfeitFromSchedule;
                remainingForfeit -= forfeitFromSchedule;

                // If schedule is now empty, remove it by swap+pop
                if (schedule.totalLocked == 0) {
                    if (i < userSchedules.length - 1) {
                        userSchedules[i] = userSchedules[
                            userSchedules.length - 1
                        ];
                    }
                    userSchedules.pop();
                }
            }
        }

        emit SchedulesForfeited(user, forfeitAmount);
    }

    /**
     * @dev A helper that calculates how many tokens have vested so far
     *      for a schedule with `active` tokens left, linear over e.g. 7 days.
     */
    function _calculateLinearVested(
        uint256 active,
        uint256 startTime
    ) internal view returns (uint256) {
        uint256 DURATION = 7 days;
        if (block.timestamp < startTime) {
            return 0; // not started
        }
        if (block.timestamp >= startTime + DURATION) {
            // fully vested
            return active;
        } else {
            // partial
            uint256 elapsed = block.timestamp - startTime;
            return (active * elapsed) / DURATION;
        }
    }

    /**
     * @dev Merge the oldest two schedules
     * @param user The address of the user
     */
    function _mergeOldestSchedules(address user) internal {
        VestingSchedule[] storage arr = schedules[user];

        // Merge the first two schedules
        arr[0].totalLocked += arr[1].totalLocked;
        arr[0].released += arr[1].released;
        if (arr[1].startTime < arr[0].startTime) {
            arr[0].startTime = arr[1].startTime;
        }

        // Shift all schedules to the left
        for (uint256 i = 1; i < arr.length - 1; i++) {
            arr[i] = arr[i + 1];
        }
        arr.pop();

        emit ScheduleMerged(user, 0, 1);
    }

    /**
     * @dev Merge all fully vested schedules into one
     * @param user The address of the user
     */
    function _mergeFullyVestedSchedules(address user) internal {
        VestingSchedule[] storage arr = schedules[user];
        if (arr.length <= 1) return;

        int256 firstVestedIndex = -1;
        for (uint256 i = 0; i < arr.length; i++) {
            if (_isFullyVested(arr[i])) {
                if (firstVestedIndex < 0) {
                    firstVestedIndex = int256(i);
                }
            }
        }
        if (firstVestedIndex < 0) {
            return;
        }
        uint256 keepIndex = uint256(firstVestedIndex);

        for (uint256 i = arr.length; i > 0; i--) {
            uint256 idx = i - 1;
            if (idx != keepIndex && _isFullyVested(arr[idx])) {
                arr[keepIndex].totalLocked += arr[idx].totalLocked;
                arr[keepIndex].released += arr[idx].released;
                if (arr[idx].startTime < arr[keepIndex].startTime) {
                    arr[keepIndex].startTime = arr[idx].startTime;
                }
                for (uint256 j = idx; j < arr.length - 1; j++) {
                    arr[j] = arr[j + 1];
                }
                arr.pop();
                if (idx < keepIndex) {
                    keepIndex--;
                }
            }
        }
    }

    // ----------------------------------
    // VESTING CALCULATION
    // ----------------------------------
    /**
     * @dev Calculate the unvested amount of tokens
     * @param user The address of the user
     * @param transferAmount The amount of tokens being transferred
     */
    function _calculateUnvested(
        address user,
        uint256 transferAmount
    ) internal view returns (uint256) {
        uint256 userBal = balanceOf(user);
        if (transferAmount > userBal) revert TransferAmountExceedsBalance();
        uint256 vested = _calculateVested(user);
        if (transferAmount <= vested) {
            return 0;
        } else {
            return transferAmount - vested;
        }
    }

    /**
     * @dev Calculate the total vested amount of tokens
     * @param user The address of the user
     */
    function _calculateVested(address user) public view returns (uint256) {
        VestingSchedule[] memory arr = schedules[user];
        uint256 total;
        for (uint256 i = 0; i < arr.length; i++) {
            total += _vestedAmount(arr[i]);
        }
        return total;
    }

    /**
     * @dev Calculate the vested amount of tokens for a given schedule
     * @param sched The schedule to calculate for
     */
    function _vestedAmount(
        VestingSchedule memory sched
    ) internal view returns (uint256) {
        uint256 active = sched.totalLocked - sched.released;
        if (active == 0) return 0;

        if (block.timestamp >= sched.startTime + VESTING_DURATION) {
            return active;
        }
        uint256 elapsed = block.timestamp - sched.startTime;
        uint256 portion = (active * elapsed) / VESTING_DURATION;
        return portion;
    }

    /**
     * @dev Check if a schedule is fully vested
     * @param sched The schedule to check
     */
    function _isFullyVested(
        VestingSchedule memory sched
    ) internal view returns (bool) {
        uint256 active = sched.totalLocked - sched.released;
        if (active == 0) return true;
        if (block.timestamp >= sched.startTime + VESTING_DURATION) return true;
        return false;
    }

    // ----------------------------------
    // MERKLE DISTRIBUTION
    // ----------------------------------
    /**
     * @dev Claim the vested amount of tokens
     * @param index The index of the claim
     * @param account The address of the user
     * @param amount The amount of tokens being claimed
     * @param merkleProof The merkle proof for the claim
     */
    function claim(
        uint256 index,
        address account,
        uint256 amount,
        bytes32[] calldata merkleProof
    ) external nonReentrant {
        if (hasClaimed[account]) revert AlreadyClaimed();
        hasClaimed[account] = true;

        bytes32 node = keccak256(abi.encodePacked(index, account, amount));
        if (!_verifyProof(merkleProof, merkleRoot, node))
            revert InvalidMerkleProof();

        if (balanceOf(address(this)) < amount)
            revert InsufficientContractBalance();
        _transfer(address(this), account, amount);

        emit Claimed(account, amount);
    }

    /**
     * @dev Verify the merkle proof
     * @param proof The merkle proof to verify
     * @param root The root of the merkle tree
     * @param leaf The leaf of the merkle tree
     */
    function _verifyProof(
        bytes32[] calldata proof,
        bytes32 root,
        bytes32 leaf
    ) internal pure returns (bool) {
        bytes32 computedHash = leaf;

        for (uint256 i = 0; i < proof.length; i++) {
            computedHash = _hashPair(computedHash, proof[i]);
        }

        return computedHash == root;
    }

    /**
     * @dev Hash two bytes32 values in a way that is compatible with solidity's keccak256
     * @param a The first bytes32 value
     * @param b The second bytes32 value
     */
    function _hashPair(bytes32 a, bytes32 b) private pure returns (bytes32) {
        return
            a <= b
                ? keccak256(abi.encodePacked(a, b))
                : keccak256(abi.encodePacked(b, a));
    }
}
