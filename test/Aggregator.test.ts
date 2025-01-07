import { expect } from "chai";
import { ethers } from "hardhat";
import { MerkleTree } from "merkletreejs";
import { keccak256 } from "ethers";
import { HardhatEthersSigner } from "@nomicfoundation/hardhat-ethers/signers";
import { VestingToken } from "../typechain-types";

// Helper function to move time forward
async function advanceTime(seconds: number): Promise<void> {
  await ethers.provider.send("evm_increaseTime", [seconds]);
  await ethers.provider.send("evm_mine", []);
}

describe("Aggregator creates a merkle tree and distributes tokens", function () {
  let token: VestingToken;
  let owner: HardhatEthersSigner;
  let treasury: HardhatEthersSigner;
  let dex: HardhatEthersSigner;
  let user1: HardhatEthersSigner;
  let user2: HardhatEthersSigner;
  let user3: HardhatEthersSigner;

  const INITIAL_SUPPLY = ethers.parseEther("1000000000");
  const BUY_AMOUNT = ethers.parseEther("1000");
  const DAY = 24 * 60 * 60;
  const VESTING_DURATION = 7 * DAY; // from your contract
  const LOCK_PERCENTAGE = 50; // from your contract

  beforeEach(async () => {
    [owner, treasury, dex, user1, user2, user3] = await ethers.getSigners();

    // Deploy
    const VestingTokenFactory = await ethers.getContractFactory("VestingToken");
    token = (await VestingTokenFactory.deploy(
      "Vesting Token",
      "VEST",
      INITIAL_SUPPLY,
      treasury.address
    )) as VestingToken;

    // Fund DEX from Treasury
    await token.connect(treasury).transfer(dex.address, ethers.parseEther("500000"));
    await token.connect(owner).setDexPair(dex.address, true);
  });

  it("Simulate multi-user buys & sells, aggregator reads schedules, and builds final Merkle distribution", async () => {
    // ---------------------------
    // STEP A: Buys & Sells
    // ---------------------------
    await token.connect(dex).transfer(user1.address, BUY_AMOUNT);
    await token.connect(dex).transfer(user2.address, BUY_AMOUNT);
    await token.connect(dex).transfer(user3.address, BUY_AMOUNT);

    await advanceTime(3 * DAY);

    const user2SellAmount = (await token.balanceOf(user2.address)) / 2n;
    await token.connect(user2).transfer(dex.address, user2SellAmount);

    await advanceTime(5 * DAY);

    await token.connect(dex).transfer(user3.address, BUY_AMOUNT);

    // ---------------------------
    // STEP B: "Aggregator" reads on-chain schedules
    // ---------------------------
    const users = [user1, user2, user3];

    // We also read how many tokens the contract itself holds => these include forfeits
    const contractBalance = await token.balanceOf(token.getAddress());
    console.log("Contract (forfeit) balance:", contractBalance.toString());

    // We'll define a small aggregator data structure
    interface AggregatorClaim {
      index: number;
      account: string;
      amount: bigint;
    }
    const aggregatorClaims: AggregatorClaim[] = [];
    let indexCounter = 0;

    // We need total "fully vested tokens" across all users to distribute forfeits proportionally
    let totalFullyVestedAll = 0n;

    // First, let's gather some info for each user
    const userData = [];

    for (const user of users) {
      const scheduleCount = await token.getScheduleCount(user.address);
      let fullyVestedSum = 0n;
      let unvestedSum = 0n;
      // used to app;y daily bonuses from first vest
      let earliestFullVestTime = 9999999999999n;

      // Loop each schedule
      for (let i = 0; i < scheduleCount; i++) {
        const sched = await token.getSchedule(user.address, i);
        const now = BigInt((await ethers.provider.getBlock("latest"))?.timestamp ?? 0);

        const totalLocked = BigInt(sched.totalLocked);
        const released = BigInt(sched.released);
        const startTime = BigInt(sched.startTime);

        // How many remain locked/unvested in this schedule
        const lockedRemaining = totalLocked - released; // might be 0 if forfeited or fully vested
        // If current time >= startTime + 7 days => schedule is fully vested
        const vestCompleteTime = startTime + BigInt(VESTING_DURATION);

        if (now >= vestCompleteTime) {
          // fully vested
          fullyVestedSum += lockedRemaining;
          if (vestCompleteTime < earliestFullVestTime) {
            earliestFullVestTime = vestCompleteTime;
          }
        } else {
          // not fully vested
          unvestedSum += lockedRemaining;
        }
      }

      // Collect data
      userData.push({
        user: user.address,
        fullyVested: fullyVestedSum,
        unvested: unvestedSum,
      });

      // We'll accumulate totalFullyVestedAll for distributing forfeits
      totalFullyVestedAll += fullyVestedSum;
    }

    // Now we see how many forfeited tokens are in contractBalance
    // We'll distribute them proportionally to each user that has >0 fullyVested
    for (const info of userData) {
      const fullyVested = info.fullyVested;
      let shareOfForfeits = 0n;
      if (totalFullyVestedAll > 0n && fullyVested > 0n) {
        shareOfForfeits = (contractBalance * fullyVested) / totalFullyVestedAll;
      }

      const finalClaim = shareOfForfeits;

      aggregatorClaims.push({
        index: indexCounter++,
        account: info.user,
        amount: finalClaim,
      });
    }

    // ---------------------------
    // STEP C: Build Merkle Tree & Post Root
    // ---------------------------
    // NOTE: Must match your contract's encoding approach (packed vs. regular)
    function leafHash(index: number, account: string, amount: bigint) {
      return ethers.keccak256(ethers.solidityPacked(["uint256", "address", "uint256"], [index, account, amount]));
    }

    const leaves = aggregatorClaims.map((c) => Buffer.from(ethers.getBytes(leafHash(c.index, c.account, c.amount))));
    const tree = new MerkleTree(leaves, keccak256, { sortPairs: true });
    const root = tree.getHexRoot();

    // Post root on-chain
    await token.connect(owner).setMerkleRoot(root);

    // ---------------------------
    // STEP D: Each user claims
    // ---------------------------
    for (const claimInfo of aggregatorClaims) {
      // build user leaf again
      const leaf = Buffer.from(ethers.getBytes(leafHash(claimInfo.index, claimInfo.account, claimInfo.amount)));
      const proof = tree.getHexProof(leaf);

      const beforeBalance = await token.balanceOf(claimInfo.account);

      // user calls claim
      const userSigner = await ethers.getSigner(claimInfo.account);
      await token.connect(userSigner).claim(claimInfo.index, claimInfo.account, claimInfo.amount, proof);

      const afterBalance = await token.balanceOf(claimInfo.account);
      expect(afterBalance - beforeBalance).to.equal(claimInfo.amount);
    }

    const finalBalance = await token.balanceOf(token.getAddress());
    expect(finalBalance).to.be.closeTo(0n, 1n);
  });
});
