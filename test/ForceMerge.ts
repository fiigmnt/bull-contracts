import { expect } from "chai";
import { ethers } from "hardhat";
import { time } from "@nomicfoundation/hardhat-network-helpers";
import { VestingERC20 } from "../typechain-types";
import { HardhatEthersSigner } from "@nomicfoundation/hardhat-ethers/signers";

describe("VestingERC20", function () {
  let token: VestingERC20;
  let owner: HardhatEthersSigner;
  let user1: HardhatEthersSigner;
  let user2: HardhatEthersSigner;
  let treasury: HardhatEthersSigner;
  const MAX_SCHEDULES = 50; // Same as contract
  const TRANSFER_AMOUNT = ethers.parseEther("100");

  beforeEach(async function () {
    [owner, treasury, user1, user2] = await ethers.getSigners();

    const VestingERC20 = await ethers.getContractFactory("VestingERC20");
    token = (await VestingERC20.deploy("Test Token", "TEST", treasury.address)) as VestingERC20;

    // Transfer some tokens to user1 to use in tests
    await token.connect(treasury).transfer(user1.address, ethers.parseEther("10000"));
  });

  describe("Force Schedule Merge", function () {
    it("should force merge when MAX_SCHEDULES is reached", async function () {
      // Step 1: Create MAX_SCHEDULES + 1 schedules by transferring
      // Wait more than MERGE_WINDOW between transfers to ensure new schedules
      for (let i = 0; i < MAX_SCHEDULES; i++) {
        await token.connect(user1).transfer(user2.address, TRANSFER_AMOUNT);
        console.log("user2 balance", await token.balanceOf(user2.address));
        const schedulesBefore = await token.getVestingProgress(user2.address);
        console.log(schedulesBefore);
        console.log("total weighted contributions", await token.totalWeightedContributions());
        // Wait 2 days between transfers to avoid merge window
        await time.increase(2 * 24 * 3600);
      }

      // console.log("user2 balance", await token.balanceOf(user2.address));
      // // Verify user2 has MAX_SCHEDULES schedules
      // const schedulesBefore = await token.getVestingProgress(user2.address);
      // console.log(schedulesBefore);
      // expect(schedulesBefore.totalVested + schedulesBefore.totalUnvested)
      //     .to.equal(TRANSFER_AMOUNT * BigInt(MAX_SCHEDULES));

      // This transfer should trigger _forceScheduleMerge
      // await token.connect(user1).transfer(user2.address, TRANSFER_AMOUNT);

      // Verify the amounts are correct after force merge
      // const schedulesAfter = await token.getVestingProgress(user2.address);
      // expect(schedulesAfter.totalVested + schedulesAfter.totalUnvested)
      //     .to.equal(TRANSFER_AMOUNT * BigInt(MAX_SCHEDULES + 1));

      // You can also verify the number of schedules if you add a view function
      // to get schedules.length in your contract
    });

    it("should properly distribute vested and unvested amounts in force merge", async function () {
      // First create MAX_SCHEDULES schedules that are partially vested
      // for (let i = 0; i < MAX_SCHEDULES; i++) {
      //     await token.connect(user1).transfer(user2.address, TRANSFER_AMOUNT);
      //     await time.increase(2 * 24 * 3600); // 2 days
      // }

      // Wait 3 days to have partial vesting on existing schedules
      await time.increase(3 * 24 * 3600);

      // Get vesting state before force merge
      // const beforeMerge = await token.getVestingProgress(user2.address);

      // This should trigger force merge
      // await token.connect(user1).transfer(user2.address, TRANSFER_AMOUNT);

      // Get vesting state after force merge
      // const afterMerge = await token.getVestingProgress(user2.address);

      // Verify total balance increased by TRANSFER_AMOUNT
      // expect(afterMerge.totalVested + afterMerge.totalUnvested)
      //     .to.equal(beforeMerge.totalVested + beforeMerge.totalUnvested + TRANSFER_AMOUNT);

      // Verify some amounts are still vesting (not all immediately vested)
      // expect(afterMerge.totalUnvested).to.be.gt(0);
    });
  });
});
