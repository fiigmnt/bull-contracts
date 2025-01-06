// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";

/**
 * @title HybridVestingTokenWithMerging
 * @notice Demonstrates:
 *   1) On-chain schedules for accurate forfeit logic on "sell."
 *   2) Merging schedules if the last is < 1 day old, plus capping at 30 schedules.
 *   3) Merkle-based distribution of forfeited tokens (off-chain aggregator for partial vest & daily bonus).
 *
 * NOT AUDITED—example only.
 */
contract HybridVestingTokenWithMerging is ERC20, Ownable {
    // ----------------------------------
    // DATA: SCHEDULES, MERGING, DEX PAIRS
    // ----------------------------------
    struct VestingSchedule {
        uint256 totalLocked;
        uint256 released;
        uint256 startTime;
    }

    // Each user can have multiple schedules
    mapping(address => VestingSchedule[]) public schedules;

    // DEX pairs for buy/sell detection
    mapping(address => bool) public dexPairs;

    // For schedule merging
    uint256 public constant MERGE_WINDOW = 1 days;
    uint256 public constant MAX_SCHEDULES = 30;

    // ----------------------------------
    // VESTING / FORFEIT CONFIG
    // ----------------------------------
    uint256 public constant VESTING_DURATION = 7 days;
    uint256 public constant LOCK_PERCENTAGE = 50; // 50% locked at buy

    // Track how many tokens have been forfeited
    // (Alternatively, you can rely on balanceOf(address(this)).
    uint256 public totalForfeitedTokens;

    // ----------------------------------
    // MERKLE DISTRIBUTION FOR OFF-CHAIN AGGREGATOR
    // ----------------------------------
    bytes32 public merkleRoot;
    mapping(address => bool) public hasClaimed;

    // ----------------------------------
    // EVENTS
    // ----------------------------------
    event DexPairUpdated(address indexed pair, bool status);
    event ScheduleMerged(address indexed user, uint256 idxA, uint256 idxB);
    event ScheduleAdded(
        address indexed user,
        uint256 lockedAmount,
        uint256 startTime
    );
    event Forfeited(address indexed user, uint256 amount);
    event MerkleRootUpdated(bytes32 oldRoot, bytes32 newRoot);
    event Claimed(address indexed user, uint256 amount);

    // ----------------------------------
    // CONSTRUCTOR
    // ----------------------------------
    constructor(
        string memory name_,
        string memory symbol_,
        uint256 initialSupply,
        address treasury
    ) ERC20(name_, symbol_) Ownable(msg.sender) {
        // Mint initial supply to treasury
        _mint(treasury, initialSupply * 10 ** decimals());
    }

    // ----------------------------------
    // OWNER FUNCTIONS
    // ----------------------------------
    function setDexPair(address pair, bool _status) external onlyOwner {
        dexPairs[pair] = _status;
        emit DexPairUpdated(pair, _status);
    }

    /**
     * @dev Off-chain aggregator sets merkleRoot periodically for distribution
     */
    function setMerkleRoot(bytes32 _merkleRoot) external onlyOwner {
        emit MerkleRootUpdated(merkleRoot, _merkleRoot);
        merkleRoot = _merkleRoot;
    }

    // ----------------------------------
    // ERC20 OVERRIDES
    // ----------------------------------
    function transfer(
        address to,
        uint256 amount
    ) public virtual override returns (bool) {
        _transferWithVesting(_msgSender(), to, amount);
        return true;
    }

    function transferFrom(
        address from,
        address to,
        uint256 amount
    ) public virtual override returns (bool) {
        address spender = _msgSender();
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
        require(from != address(0), "Transfer from zero");
        require(to != address(0), "Transfer to zero");

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
                totalForfeitedTokens += unvested;
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
    function _addVestingSchedule(address user, uint256 lockedAmount) internal {
        VestingSchedule[] storage arr = schedules[user];
        uint256 len = arr.length;

        if (len > 0) {
            // check last schedule
            VestingSchedule storage lastSched = arr[len - 1];
            // If the last schedule is < MERGE_WINDOW old and not fully vested, merge
            if (
                (block.timestamp - lastSched.startTime) < MERGE_WINDOW &&
                !_isFullyVested(lastSched)
            ) {
                // merge new tokens into last schedule
                lastSched.totalLocked += lockedAmount;
                emit ScheduleAdded(user, lockedAmount, lastSched.startTime);

                // Then merge fully vested schedules
                _mergeFullyVestedSchedules(user);

                // If we still exceed 30, do oldest merge
                if (arr.length > MAX_SCHEDULES) {
                    _mergeOldestSchedules(user);
                }
                return;
            }
        }

        // Otherwise, create new schedule
        VestingSchedule memory newSched = VestingSchedule({
            totalLocked: lockedAmount,
            released: 0,
            startTime: block.timestamp
        });
        arr.push(newSched);
        emit ScheduleAdded(user, lockedAmount, block.timestamp);

        // Merge fully vested
        _mergeFullyVestedSchedules(user);

        // If we exceed 30, merge oldest
        if (arr.length > MAX_SCHEDULES) {
            _mergeOldestSchedules(user);
        }
    }

    /**
     * @dev Merge the oldest two schedules to cap at 30
     */
    function _mergeOldestSchedules(address user) internal {
        VestingSchedule[] storage arr = schedules[user];
        if (arr.length < 2) return;

        // Merge arr[0] and arr[1]
        arr[0].totalLocked += arr[1].totalLocked;
        arr[0].released += arr[1].released;
        if (arr[1].startTime < arr[0].startTime) {
            arr[0].startTime = arr[1].startTime;
        }

        // remove arr[1]
        for (uint256 i = 1; i < arr.length - 1; i++) {
            arr[i] = arr[i + 1];
        }
        arr.pop();

        emit ScheduleMerged(user, 0, 1);
    }

    /**
     * @dev Merge all fully vested schedules into the first fully vested schedule
     *      so user never holds more than 1 fully vested schedule.
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
                // remove arr[idx]
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
     * @dev Calculate how many tokens are unvested if user tries to move `transferAmount`.
     *      We'll do a naive approach: unvested = transferAmount - vestedIfNeeded
     *      if the user tries to move more than their total vested.
     */
    function _calculateUnvested(
        address user,
        uint256 transferAmount
    ) internal view returns (uint256) {
        uint256 userBal = balanceOf(user);
        require(userBal >= transferAmount, "Transfer>balance");
        uint256 vested = _calculateVested(user);
        if (transferAmount <= vested) {
            return 0;
        } else {
            return transferAmount - vested;
        }
    }

    function _calculateVested(address user) public view returns (uint256) {
        VestingSchedule[] memory arr = schedules[user];
        uint256 total;
        for (uint256 i = 0; i < arr.length; i++) {
            total += _vestedAmount(arr[i]);
        }
        return total;
    }

    function _vestedAmount(
        VestingSchedule memory sched
    ) internal view returns (uint256) {
        uint256 active = sched.totalLocked - sched.released;
        if (active == 0) return 0;

        if (block.timestamp >= sched.startTime + VESTING_DURATION) {
            return active; // fully vested
        }
        // partial linear vest
        uint256 elapsed = block.timestamp - sched.startTime;
        uint256 portion = (active * elapsed) / VESTING_DURATION;
        return portion;
    }

    function _isFullyVested(
        VestingSchedule memory sched
    ) internal view returns (bool) {
        uint256 active = sched.totalLocked - sched.released;
        if (active == 0) return true;
        if (block.timestamp >= sched.startTime + VESTING_DURATION) return true;
        return false;
    }

    // ----------------------------------
    // MERKLE DISTRIBUTION (OFF-CHAIN)
    // ----------------------------------
    function claim(
        uint256 index,
        address account,
        uint256 amount,
        bytes32[] calldata merkleProof
    ) external {
        require(!hasClaimed[account], "Already claimed");
        hasClaimed[account] = true;

        // Verify merkle proof
        bytes32 node = keccak256(abi.encodePacked(index, account, amount));
        require(_verifyProof(merkleProof, merkleRoot, node), "Invalid proof");

        // Transfer from contract to user
        require(balanceOf(address(this)) >= amount, "Not enough tokens here");
        _transfer(address(this), account, amount);

        emit Claimed(account, amount);
    }

    function _verifyProof(
        bytes32[] calldata proof,
        bytes32 root,
        bytes32 leaf
    ) internal pure returns (bool) {
        bytes32 computedHash = leaf;
        for (uint256 i = 0; i < proof.length; i++) {
            bytes32 proofElement = proof[i];
            if (computedHash <= proofElement) {
                computedHash = keccak256(
                    abi.encodePacked(computedHash, proofElement)
                );
            } else {
                computedHash = keccak256(
                    abi.encodePacked(proofElement, computedHash)
                );
            }
        }
        return computedHash == root;
    }
}
