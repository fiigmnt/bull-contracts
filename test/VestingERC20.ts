import { time, loadFixture } from "@nomicfoundation/hardhat-toolbox/network-helpers";
import { expect } from "chai";
import hre from "hardhat";

describe("VestingERC20", function () {
  // Constants used across tests
  const VESTING_DURATION = 7 * 24 * 60 * 60; // 7 days in seconds
  const MERGE_WINDOW = 24 * 60 * 60; // 24 hours in seconds
  const TRANSFER_AMOUNT = 1000;
  const ONE_HOUR = 60 * 60;
  const ONE_DAY = 24 * 60 * 60;

  // Add after fixture function
  async function advanceTime(seconds: number) {
    await time.increase(seconds);
  }

  async function getCurrentTime() {
    return await time.latest();
  }

  async function deployVestingTokenFixture() {
    const [owner, treasury, user1, user2] = await hre.ethers.getSigners();
    const VestingERC20 = await hre.ethers.getContractFactory("VestingERC20");
    const token = await VestingERC20.deploy("VestingToken", "VEST", treasury.address);

    return { token, owner, treasury, user1, user2 };
  }

  describe("Deployment", function () {
    it("Should set the right owner", async function () {
      const { token, owner } = await loadFixture(deployVestingTokenFixture);
      expect(await token.owner()).to.equal(owner.address);
    });

    it("Should assign total supply to treasury", async function () {
      const { token, treasury } = await loadFixture(deployVestingTokenFixture);
      const treasuryBalance = await token.balanceOf(treasury.address);
      expect(await token.totalSupply()).to.equal(treasuryBalance);
    });
  });

  describe("Vesting", function () {
    it("Should create a new vesting schedule on transfer", async function () {
      const { token, treasury, user1 } = await loadFixture(deployVestingTokenFixture);

      await expect(token.connect(treasury).transfer(user1.address, TRANSFER_AMOUNT))
        .to.emit(token, "VestingStarted")
        .withArgs(user1.address, TRANSFER_AMOUNT);

      const vestSchedules = await token.vestSchedules(user1.address, 0);
      expect(vestSchedules.initialBalance).to.equal(TRANSFER_AMOUNT);
      expect(vestSchedules.withheldAmount).to.equal(TRANSFER_AMOUNT / 2);
    });

    it("Should vest 50% immediately", async function () {
      const { token, treasury, user1 } = await loadFixture(deployVestingTokenFixture);

      await token.connect(treasury).transfer(user1.address, TRANSFER_AMOUNT);

      const vestedBalance = await token.getVestedBalance(user1.address);
      expect(vestedBalance).to.equal(TRANSFER_AMOUNT / 2);
    });

    it("Should vest linearly over 7 days", async function () {
      const { token, treasury, user1 } = await loadFixture(deployVestingTokenFixture);

      await token.connect(treasury).transfer(user1.address, TRANSFER_AMOUNT);
      const initialVested = await token.getVestedBalance(user1.address);

      // Move halfway through vesting period
      await time.increase(VESTING_DURATION / 2);

      const halfwayVested = await token.getVestedBalance(user1.address);
      const expectedHalfway = TRANSFER_AMOUNT * 0.75; // 50% immediate + 25% of remaining
      expect(halfwayVested).to.be.closeTo(expectedHalfway, 1); // Allow for small rounding
    });

    // Add to Vesting describe block
    it("Should handle zero amount transfers", async function () {
      const { token, treasury, user1 } = await loadFixture(deployVestingTokenFixture);
      await expect(token.connect(treasury).transfer(user1.address, 0)).to.not.emit(token, "VestingStarted");
    });

    it("Should handle multiple vesting schedules correctly with no merge", async function () {
      const { token, treasury, user1 } = await loadFixture(deployVestingTokenFixture);

      await token.connect(treasury).transfer(user1.address, TRANSFER_AMOUNT);
      await advanceTime(MERGE_WINDOW + ONE_HOUR);
      await token.connect(treasury).transfer(user1.address, TRANSFER_AMOUNT);
      await advanceTime(MERGE_WINDOW + ONE_HOUR);
      await token.connect(treasury).transfer(user1.address, TRANSFER_AMOUNT);

      let totalVested = await token.getVestedBalance(user1.address);
      expect(totalVested).to.be.closeTo((TRANSFER_AMOUNT * 3) / 2, 500); // account for % interest

      await advanceTime(VESTING_DURATION);

      totalVested = await token.getVestedBalance(user1.address);
      expect(totalVested).to.equal(TRANSFER_AMOUNT * 3);
    });

    it("Should handle multiple vesting schedules correctly with merge", async function () {
      const { token, treasury, user1 } = await loadFixture(deployVestingTokenFixture);

      await token.connect(treasury).transfer(user1.address, TRANSFER_AMOUNT); 
      await advanceTime(ONE_HOUR);
      await token.connect(treasury).transfer(user1.address, TRANSFER_AMOUNT);
      await advanceTime(ONE_HOUR);
      await token.connect(treasury).transfer(user1.address, TRANSFER_AMOUNT);

      let totalVested = await token.getVestedBalance(user1.address);
      expect(totalVested).to.be.closeTo((TRANSFER_AMOUNT * 3) / 2, 500); // account for % interest

      await advanceTime(VESTING_DURATION);

      totalVested = await token.getVestedBalance(user1.address);
      expect(totalVested).to.equal(TRANSFER_AMOUNT * 3);
    });

    // Add to Forfeiture describe block
    it("Should handle forfeiture with multiple schedules", async function () {
      const { token, treasury, user1, user2 } = await loadFixture(deployVestingTokenFixture);

      // Create 2 schedules
      await token.connect(treasury).transfer(user1.address, TRANSFER_AMOUNT);
      await advanceTime(MERGE_WINDOW + ONE_HOUR);
      await token.connect(treasury).transfer(user1.address, TRANSFER_AMOUNT);

      // Transfer full amount
      const totalAmount = TRANSFER_AMOUNT * 2;
      await expect(token.connect(user1).transfer(user2.address, totalAmount)).to.emit(token, "Forfeited");

      // Check forfeited amount is correct
      const forfeitedPool = await token.forfeitedPool();
      expect(forfeitedPool).to.be.closeTo(totalAmount / 2, 500); // account for % interest
    });

    it("Should forfeit unvested tokens when selling to DEX", async function () {
      const { token, treasury, user1, user2 } = await loadFixture(deployVestingTokenFixture);

      // Set up DEX address
      await token.setVestingExemption(user1.address, true);

      // Give user2 some tokens
      await token.connect(treasury).transfer(user2.address, TRANSFER_AMOUNT);

      // Try to sell entire amount to DEX immediately
      await expect(token.connect(user2).transfer(user1.address, TRANSFER_AMOUNT))
        .to.emit(token, "Forfeited")
        .withArgs(user2.address, TRANSFER_AMOUNT / 2); // Should forfeit unvested half

      // Check forfeited pool increased
      expect(await token.forfeitedPool()).to.equal(TRANSFER_AMOUNT / 2);

      // Check actual transfer amount was only vested portion
      expect(await token.balanceOf(user1.address)).to.equal(TRANSFER_AMOUNT / 2);
    });
  });

  describe("Schedule Merging", function () {
    it("Should merge transfers within 24 hours", async function () {
      const { token, treasury, user1 } = await loadFixture(deployVestingTokenFixture);

      // First transfer
      await token.connect(treasury).transfer(user1.address, TRANSFER_AMOUNT);

      // Second transfer within merge window
      await time.increase(MERGE_WINDOW - ONE_HOUR);
      await token.connect(treasury).transfer(user1.address, TRANSFER_AMOUNT);

      // Should only have one schedule
      await expect(token.vestSchedules(user1.address, 1)).to.be.reverted; // invalid array access

      const schedule = await token.vestSchedules(user1.address, 0);
      expect(schedule.initialBalance).to.equal(TRANSFER_AMOUNT * 2);
    });

    it("Should create new schedule after merge window", async function () {
      const { token, treasury, user1 } = await loadFixture(deployVestingTokenFixture);

      // First transfer
      await token.connect(treasury).transfer(user1.address, TRANSFER_AMOUNT);

      // Second transfer after merge window
      await time.increase(MERGE_WINDOW + ONE_HOUR);
      await token.connect(treasury).transfer(user1.address, TRANSFER_AMOUNT);

      // Should have two schedules
      const schedule1 = await token.vestSchedules(user1.address, 0);
      const schedule2 = await token.vestSchedules(user1.address, 1);

      expect(schedule1.initialBalance).to.equal(TRANSFER_AMOUNT);
      expect(schedule2.initialBalance).to.equal(TRANSFER_AMOUNT);
    });
  });

  describe("Forfeiture", function () {
    it("Should forfeit unvested tokens on early transfer", async function () {
      const { token, treasury, user1, user2 } = await loadFixture(deployVestingTokenFixture);

      // Initial transfer to user1
      await token.connect(treasury).transfer(user1.address, TRANSFER_AMOUNT);

      // User1 tries to transfer full amount immediately
      await expect(token.connect(user1).transfer(user2.address, TRANSFER_AMOUNT))
        .to.emit(token, "Forfeited")
        .withArgs(user1.address, TRANSFER_AMOUNT / 2); // Should forfeit unvested half

      expect(await token.forfeitedPool()).to.equal(TRANSFER_AMOUNT / 2);
    });

    it("Should allow claiming forfeited tokens after full vest", async function () {
      const { token, treasury, user1, user2 } = await loadFixture(deployVestingTokenFixture);

      // Setup: Create some forfeited tokens
      await token.connect(treasury).transfer(user1.address, TRANSFER_AMOUNT); // user buys 1000 tokens
      await token.connect(treasury).transfer(user2.address, TRANSFER_AMOUNT); // user buys 1000 tokens
      await token.connect(user2).transfer(user1.address, TRANSFER_AMOUNT); // user sells 1000 tokens and forfeits 500

      // Wait for full vesting
      await time.increase(VESTING_DURATION);

      // User2 should be able to claim
      await expect(token.connect(user1).claim()).to.emit(token, "Claimed").withArgs(user1.address, 500);
    });
  });

  describe("Daily Compounding", function () {
    it("Should increase share after vesting completion", async function () {
      const { token, treasury, user1, user2 } = await loadFixture(deployVestingTokenFixture);

      await token.connect(treasury).transfer(user1.address, TRANSFER_AMOUNT);
      // Wait for vesting + 1 day
      await time.increase(VESTING_DURATION + ONE_DAY);
      await token.connect(user1).transfer(user2.address, 100); // trigger vesting true
      await time.increase(ONE_DAY);
      await token.connect(user1).transfer(user2.address, 100); // trigger multiple update


      const schedule = await token.vestSchedules(user1.address, 0);
      expect(schedule.multiple).to.be.gt(hre.ethers.parseUnits("1", 18)); // Should be > 1.0
    });
  });

  // Add new describe block
  describe("Error cases", function () {
    it("Should forfeit unvested tokens when selling", async function () {
      const { token, treasury, user1, user2 } = await loadFixture(deployVestingTokenFixture);

      await token.connect(treasury).transfer(user1.address, TRANSFER_AMOUNT);

      // Try to transfer more than vested amount
      const vestedAmount = await token.getVestedBalance(user1.address);
      await expect(token.connect(user1).transfer(user2.address, 1000))
        .to.emit(token, "Forfeited")
        .withArgs(user1.address, 500);

      expect(await token.balanceOf(user2.address)).to.equal(500);
      expect(await token.forfeitedPool()).to.equal(500);
    });

    it("Should revert when claiming with no forfeited tokens", async function () {
      const { token, user1 } = await loadFixture(deployVestingTokenFixture);
      await expect(token.connect(user1).claim()).to.be.revertedWithCustomError(token, "NothingToClaim");
    });
  });
});
