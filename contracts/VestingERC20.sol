// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import {PRBMathUD60x18} from "prb-math/contracts/PRBMathUD60x18.sol";

/**
 * DISCLAIMER:
 * This contract is a conceptual example of an ERC-20 that
 * integrates vesting + forfeiture logic *directly* into its transfer.
 * It is NOT production-ready and requires heavy testing, auditing,
 * and likely significant optimizations.
 */

abstract contract Context {
    function _msgSender() internal view virtual returns (address) {
        return msg.sender;
    }
}

interface IERC20 {
    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(
        address indexed owner,
        address indexed spender,
        uint256 value
    );

    function totalSupply() external view returns (uint256);

    function balanceOf(address account) external view returns (uint256);

    function transfer(address to, uint256 amount) external returns (bool);

    function allowance(
        address owner,
        address spender
    ) external view returns (uint256);

    function approve(address spender, uint256 amount) external returns (bool);

    function transferFrom(
        address from,
        address to,
        uint256 amount
    ) external returns (bool);
}

contract VestingERC20 is Context, IERC20 {
    using PRBMathUD60x18 for uint256;

    // -------------------------
    // ERC-20 Metadata
    // -------------------------
    string public name = "Vesting Token";
    string public symbol = "VEST";
    uint8 public decimals = 18;

    uint256 private _totalSupply;
    mapping(address => uint256) private _balances;

    mapping(address => mapping(address => uint256)) private _allowances;

    // -------------------------
    // Vesting / Forfeiture
    // -------------------------
    uint256 constant VESTING_DURATION = 7 days;
    uint256 constant SCALE = 1e18;
    uint256 constant DAILY_INCREMENT = 1e16; // 1% of SCALE
    
    // In PRBMath UD60x18, "1e18" means "1.0". So 1.01 * 1e18 = 1_010000000000000000
    uint256 public constant DAILY_RATE = 1_010000000000000000; // 1.01 * 1e18

    struct VestingInfo {
        bool exists;
        bool fullyVested;
        uint256 initialBalance; // total tokens that triggered vesting for this user
        uint256 withheldAmount; // half that vests over 7 days
        uint256 vestStart;
        uint256 vestComplete;
        // For 1% daily growth after vesting
        uint256 multiple; // starts at 0, becomes SCALE (1.0) on full vest
        uint256 lastMultipleUpdate;
        // For claim tracking
        uint256 claimedForfeits; // how many forfeited tokens they've already claimed
    }

    // Track vesting details per user
    mapping(address => VestingInfo) public vestInfo;

    // Forfeited pool: tokens lost by senders who transferred unvested amounts
    uint256 public forfeitedPool;

    // Weighted contributions for fully vested users:
    // userWeightedContrib = (balanceOf(user) * user.multiple)
    mapping(address => uint256) public userWeightedContribution;
    uint256 public totalWeightedContributions;

    // -------------------------
    // Events
    // -------------------------
    event Forfeited(address indexed from, uint256 amount);
    event VestingStarted(address indexed user, uint256 amount);
    event Claimed(address indexed user, uint256 forfeitedAmount);

    constructor() {
        // Example: mint some tokens to deployer
        _mint(_msgSender(), 1000000 * 10 ** decimals);
    }

    // -------------------------
    // ERC-20 Standard Functions
    // -------------------------
    function totalSupply() public view override returns (uint256) {
        return _totalSupply;
    }

    function balanceOf(address account) public view override returns (uint256) {
        return _balances[account];
    }

    function transfer(
        address to,
        uint256 amount
    ) public override returns (bool) {
        _transfer(_msgSender(), to, amount);
        return true;
    }

    function allowance(
        address owner,
        address spender
    ) public view override returns (uint256) {
        return _allowances[owner][spender];
    }

    function approve(
        address spender,
        uint256 amount
    ) public override returns (bool) {
        address owner = _msgSender();
        _approve(owner, spender, amount);
        return true;
    }

    function transferFrom(
        address from,
        address to,
        uint256 amount
    ) public override returns (bool) {
        address spender = _msgSender();
        _spendAllowance(from, spender, amount);
        _transfer(from, to, amount);
        return true;
    }

    // -------------------------
    // ERC-20 Internal Logic
    // -------------------------
    function _transfer(address from, address to, uint256 amount) internal {
        require(from != address(0), "VestingERC20: from zero address");
        require(to != address(0), "VestingERC20: to zero address");

        // Update user vesting state before any transfer logic
        _updateVestingState(from);

        // Check how many tokens are truly vested/transferable for 'from'
        uint256 vestedBal = _getVestedBalance(from);
        require(
            _balances[from] >= amount,
            "VestingERC20: transfer exceeds balance"
        );

        // If the user tries to transfer more than they have vested, the difference is unvested => Forfeit
        uint256 unvested = 0;
        if (amount > vestedBal) {
            unvested = amount - vestedBal;
        }

        // Subtract the full amount from sender
        _balances[from] -= amount;

        // If there is unvested portion, forfeit it
        if (unvested > 0) {
            forfeitedPool += unvested;
            // Reduce withheldAmount to avoid double counting
            VestingInfo storage info = vestInfo[from];
            if (unvested <= info.withheldAmount) {
                info.withheldAmount -= unvested;
            } else {
                info.withheldAmount = 0;
            }
            emit Forfeited(from, unvested);

            // The receiver only gets the vested portion
            amount = vestedBal;
        }

        // Increase the balance of 'to'
        _balances[to] += amount;
        emit Transfer(from, to, amount);

        // Optionally, you might want to start vesting for 'to' if this is a brand-new "investment."
        // That depends on your use-case. For demonstration, we do not start new vesting automatically here.
        // If you want each incoming transfer to vest, you'd call something like _startVesting(to, amount).
    }

    function _mint(address account, uint256 amount) internal {
        require(account != address(0), "VestingERC20: mint to zero address");
        _totalSupply += amount;
        _balances[account] += amount;
        emit Transfer(address(0), account, amount);
    }

    function _approve(address owner, address spender, uint256 amount) internal {
        require(owner != address(0), "VestingERC20: approve from zero");
        require(spender != address(0), "VestingERC20: approve to zero");
        _allowances[owner][spender] = amount;
        emit Approval(owner, spender, amount);
    }

    function _spendAllowance(
        address owner,
        address spender,
        uint256 amount
    ) internal {
        uint256 currentAllowance = allowance(owner, spender);
        if (currentAllowance != type(uint256).max) {
            require(
                currentAllowance >= amount,
                "VestingERC20: insufficient allowance"
            );
            _approve(owner, spender, currentAllowance - amount);
        }
    }

    // -------------------------
    // Vesting: Setup & State Updates
    // -------------------------
    /**
     * Example function to start vesting on an existing balance.
     * For instance, if a user "buys in" with `amount`, half is locked.
     * We record that in vestInfo so partial tokens are withheld for 7 days.
     */
    function startVesting(address user, uint256 amount) external {
        require(user != address(0), "Zero user");
        require(balanceOf(user) >= amount, "User doesn't have enough tokens");

        VestingInfo storage info = vestInfo[user];
        info.exists = true;
        // If user invests multiple times, accumulate data:
        info.initialBalance += amount;
        // withheld is half of that
        info.withheldAmount += (amount / 2);
        info.vestStart = block.timestamp;
        info.vestComplete = block.timestamp + VESTING_DURATION;

        emit VestingStarted(user, amount);
    }

    /**
     * Updates user vesting if vestComplete is reached or if we need
     * to apply the 1% daily growth for fully vested users.
     */
    function _updateVestingState(address user) internal {
        VestingInfo storage info = vestInfo[user];
        if (!info.exists) return;

        // If user is now past the vesting window but wasn't flagged as fully vested yet, update them
        if (!info.fullyVested && block.timestamp >= info.vestComplete) {
            info.fullyVested = true;
            info.multiple = SCALE; // start at 1.0
            info.lastMultipleUpdate = block.timestamp;

            // Now that they're fully vested, we add them into the weighted contribution system
            _updateWeightedContribution(user, true);
        }
        // If they’re already fully vested, apply the daily multiplier updates
        else if (info.fullyVested) {
            _applyDailyIncrement(user);
        }
    }

    // Linear vesting: immediate half, plus withheld vesting linearly
    function _getVestedBalance(address user) public view returns (uint256) {
        VestingInfo memory info = vestInfo[user];
        uint256 actualBalance = _balances[user];
        if (!info.exists) {
            return actualBalance;
        }

        // If fully vested, user can move everything in their balance
        if (info.fullyVested) {
            return actualBalance;
        }

        // Otherwise, partially vested:
        uint256 immediate = info.initialBalance / 2;
        // how much withheld is vested now?
        uint256 timePassed = block.timestamp > info.vestComplete
            ? VESTING_DURATION
            : (block.timestamp - info.vestStart);
        uint256 vestedWithheld = (info.withheldAmount * timePassed) /
            VESTING_DURATION;

        uint256 totalVested = immediate + vestedWithheld;
        // user can't vest more than they actually have
        if (totalVested > actualBalance) {
            return actualBalance;
        } else {
            return totalVested;
        }
    }

    // -------------------------
    // Daily 1% Growth
    // -------------------------
    function _applyDailyIncrement(address user) internal {
        VestingInfo storage info = vestInfo[user];
        uint256 daysPassed = (block.timestamp - info.lastMultipleUpdate) /
            1 days;
        if (daysPassed == 0) return;

        // Remove old contribution from total
        uint256 oldWeighted = userWeightedContribution[user];
        totalWeightedContributions -= oldWeighted;

        // newMultiple = oldMultiplier * (1.01^daysPassed)
        // oldMultiplier and dailyRate are in 60.18
        uint256 exponent = daysPassed * SCALE;
        uint256 growthFactor = DAILY_RATE.pow(exponent);
        info.multiple = info.multiple.mul(growthFactor);

        // Recalculate user weighted
        info.lastMultipleUpdate += daysPassed * 1 days;
        uint256 newWeighted = (balanceOf(user) * info.multiple) / SCALE;
        userWeightedContribution[user] = newWeighted;
        totalWeightedContributions += newWeighted;
    }

    /**
     * Called when a user first becomes fully vested (or if their balance changes drastically).
     * The `addOrRemove` parameter indicates if we’re adding them to the system or removing them
     * if their balance goes to zero. In this simple version, we only add once they vest.
     */
    function _updateWeightedContribution(
        address user,
        bool addOrRemove
    ) internal {
        uint256 oldWeighted = userWeightedContribution[user];
        if (oldWeighted > 0) {
            totalWeightedContributions -= oldWeighted;
            userWeightedContribution[user] = 0;
        }

        if (addOrRemove) {
            // fresh calculation
            // Their multiple is at least 1.0
            uint256 newWeighted = (balanceOf(user) * vestInfo[user].multiple) /
                SCALE;
            userWeightedContribution[user] = newWeighted;
            totalWeightedContributions += newWeighted;
        }
    }

    // -------------------------
    // Claiming Forfeited Pool
    // -------------------------
    /**
     * getClaimable() – a view function so your front-end can display how many tokens
     * from the forfeited pool a user can claim right now.
     */
    function getClaimable(address user) public view returns (uint256) {
        VestingInfo memory info = vestInfo[user];
        if (!info.fullyVested || totalWeightedContributions == 0) {
            return 0;
        }
        // Weighted share
        uint256 userWeighted = (balanceOf(user) * info.multiple) / SCALE;
        uint256 userShare = (userWeighted * forfeitedPool) /
            totalWeightedContributions;
        // user can only claim what's above what they've claimed before
        if (userShare <= info.claimedForfeits) {
            return 0;
        }
        return (userShare - info.claimedForfeits);
    }

    /**
     * claim() – user calls this to claim their share of the forfeitedPool.
     * We recalculate how much they can claim, transfer it out, and mark them as claimed.
     */
    function claim() external {
        _updateVestingState(_msgSender()); // update multiple, etc.

        uint256 claimable = getClaimable(_msgSender());
        require(claimable > 0, "Nothing to claim");

        // update user’s claimedForfeits
        vestInfo[_msgSender()].claimedForfeits += claimable;
        // remove from global forfeitedPool
        forfeitedPool -= claimable;
        // send tokens
        _balances[address(this)] += 0; // no-op, just for demonstration if we minted from contract
        _balances[_msgSender()] += claimable;
        emit Transfer(address(0), _msgSender(), claimable); // or "from the contract" if you minted to the contract

        emit Claimed(_msgSender(), claimable);
    }
}
