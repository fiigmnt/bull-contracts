# BullRider ERC20 Token

## Overview
BullRider is a custom ERC20 token with built-in vesting mechanisms and a Merkle-based reward distribution system. The contract implements:

- **Vesting on buys**: 50% of tokens are locked upon purchase with a 7-day linear vesting schedule.
- **Forfeiture on early sales**: Unvested tokens are forfeited if sold before the vesting period completes.
- **Efficient vesting schedules**: Merging of vesting schedules within a 1-day window to prevent storage bloat.
- **Merkle-based reward distribution**: Off-chain aggregation and periodic reward claims via a Merkle proof system.
- **Security features**: Protection against dust attacks, reentrancy vulnerabilities, and excessive storage usage.

> **Note**: This contract is an **example implementation** and has **not been audited**. Use at your own risk.

## Features
### Vesting Mechanism
- 50% of purchased tokens are locked with a **7-day vesting period**.
- Unvested tokens are forfeited upon selling.
- Vesting schedules are merged if they fall within a **1-day window** to optimize storage.
- Minimum vesting amount prevents dust attacks.

### Reward Distribution via Merkle Tree
- Users can **claim vested tokens and bonuses** via a Merkle proof.
- The off-chain aggregator tracks fully vested tokens and **distributes forfeited tokens** pro-rata.
- 1% daily bonus for **long-term holders** after full vesting.

### Security Measures
- **ReentrancyGuard** prevents double-spend attacks.
- **Storage capping** prevents excessive schedule creation.
- **Dex pair management** ensures proper buy/sell detection.

## Deployment
The contract is deployed using Hardhat and Hardhat Ignition.

### Requirements
- Node.js & npm/yarn
- Hardhat
- Hardhat Ignition
- OpenZeppelin Contracts

### Installation
```sh
yarn install
```

### Compilation
```sh
yarn compile
```

### Deployment
Deploy to a test network (e.g., Sepolia):
```sh
yarn deploy:test
```
Deploy to a local network:
```sh
yarn deploy:dev
```

## Testing
Run unit tests using Hardhat:
```sh
yarn test
```

## Contract Functions
### Owner Functions
- `setDexPair(address pair, bool status)`: Adds or removes a DEX pair.
- `setMerkleRoot(bytes32 _merkleRoot)`: Updates the Merkle root for reward claims.
- `setMergeWindow(uint256 _mergeWindow)`: Modifies the schedule merging window.

### View Functions
- `getScheduleCount(address user)`: Returns the number of vesting schedules for a user.
- `getSchedule(address user, uint256 index)`: Retrieves details of a user's vesting schedule.
- `userTotalLocked(address user)`: Returns the total locked amount for a user.
- `userTotalUnvested(address user)`: Returns the amount of unvested tokens.
- `timeUntilFullyVested(address user)`: Returns time left until all tokens are vested.
- `previewSellForfeit(address user, uint256 sellAmount)`: Estimates forfeited tokens upon a sale.

### Token Transfer Logic
- **Buying tokens (from a DEX pair):**
  - 50% of tokens are immediately available.
  - 50% are locked and vest over 7 days.
- **Selling tokens (to a DEX pair):**
  - Unvested tokens are forfeited.
- **Transfers between users:**
  - No vesting or forfeiture is applied.

### Claiming Rewards
- `claim(uint256 index, address account, uint256 amount, bytes32[] calldata merkleProof)`: Claims vested tokens and bonuses using a Merkle proof.

## Example Usage
### Buying Tokens
When purchasing from a DEX:
- If a user buys `1000` tokens, `500` tokens are available immediately.
- `500` tokens are locked and vest over `7 days`.

### Selling Tokens
If a user sells before the 7-day vesting period is complete:
- Unvested tokens are forfeited.
- Forfeited tokens are distributed to long-term holders via the Merkle reward system.

## Project Structure
```
├── contracts/
│   ├── VestingToken.sol    # Main ERC20 contract with vesting
├── ignition/
│   ├── DeployVestingERC20Module.ts  # Deployment script
├── test/
│   ├── VestingToken.test.ts  # Hardhat test cases
├── hardhat.config.ts
├── package.json
├── README.md
```

## License
This project is licensed under the MIT License.

## Disclaimer
This contract has **not been audited**. Do your own research before deploying to mainnet.

