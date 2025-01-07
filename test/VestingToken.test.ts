import { expect } from "chai";
import { ethers } from "hardhat";
import { ContractFactory, BigNumberish } from "ethers";
import { MerkleTree } from "merkletreejs";
import { keccak256, solidityPacked } from "ethers";
import { HardhatEthersSigner } from "@nomicfoundation/hardhat-ethers/signers";
import { VestingToken } from "../typechain-types/contracts/VestingToken";

describe("VestingToken", function () {
  let VestingToken: ContractFactory;
  let token: VestingToken;
  let owner: HardhatEthersSigner;
  let treasury: HardhatEthersSigner;
  let dex: HardhatEthersSigner;
  let user1: HardhatEthersSigner;
  let user2: HardhatEthersSigner;
  let user3: HardhatEthersSigner;

  const INITIAL_SUPPLY: number = 1_000_000_000;
  const LOCK_PERCENTAGE: number = 50;
  const VESTING_DURATION: number = 7 * 24 * 60 * 60; // 7 days in seconds
  const MAX_SCHEDULES: number = 30;

  interface MerkleTreeClaim {
    index: number;
    account: string;
    amount: BigNumberish;
  }

  interface MerkleTreeResult {
    root: string;
    proofs: string[][];
  }

  // Helper function to move time forward
  async function advanceTime(seconds: number): Promise<void> {
    await ethers.provider.send("evm_increaseTime", [seconds]);
    await ethers.provider.send("evm_mine", []);
  }

  // Helper function to generate Merkle tree and proofs
  function generateMerkleTreeAndProofs(claims: MerkleTreeClaim[]): MerkleTreeResult {
    const leaves: Buffer[] = claims.map((claim) =>
      Buffer.from(
        ethers.getBytes(
          ethers.keccak256(
            solidityPacked(["uint256", "address", "uint256"], [claim.index, claim.account, claim.amount])
          )
        )
      )
    );

    const merkleTree = new MerkleTree(leaves, keccak256, { sortPairs: true });
    const root: string = merkleTree.getHexRoot();

    const proofs: string[][] = claims.map((claim) => {
      const leaf = keccak256(
        solidityPacked(["uint256", "address", "uint256"], [claim.index, claim.account, claim.amount])
      );
      return merkleTree.getHexProof(leaf);
    });

    return { root, proofs };
  }

  beforeEach(async function () {
    // Get signers
    [owner, treasury, dex, user1, user2, user3] = await ethers.getSigners();

    // Deploy contract
    VestingToken = await ethers.getContractFactory("VestingToken");
    token = (await VestingToken.deploy("Vesting Token", "VEST", INITIAL_SUPPLY, treasury.address)) as VestingToken;
  });

  describe("Basic Setup", function () {
    it("Should initialize with correct name and symbol", async function () {
      expect(await token.name()).to.equal("Vesting Token");
      expect(await token.symbol()).to.equal("VEST");
    });

    it("Should mint initial supply to treasury", async function () {
      const expectedSupply: BigNumberish = ethers.parseUnits(INITIAL_SUPPLY.toString(), 18);
      expect(await token.balanceOf(treasury.address)).to.equal(expectedSupply);
    });
  });

  describe("Buy/Sell Mechanics", function () {
    beforeEach(async function () {
      // Set up DEX pair
      await token.connect(treasury).transfer(dex.address, ethers.parseEther("1000000"));
      await token.setDexPair(dex.address, true);
    });

    it("Should lock 50% of tokens on buy", async function () {
      const BUY_AMOUNT: BigNumberish = ethers.parseEther("100");
      // Simulate buy from DEX
      await token.connect(dex).transfer(user1.address, BUY_AMOUNT);

      const expectedLocked = (BUY_AMOUNT * BigInt(LOCK_PERCENTAGE)) / 100n;
      const expectedImmediate = BUY_AMOUNT - expectedLocked;

      expect(await token.balanceOf(user1.address)).to.equal(expectedImmediate);
      expect(await token.userTotalLocked(user1.address)).to.equal(expectedLocked);
    });

    it("Should forfeit unvested tokens on early sell", async function () {
      const BUY_AMOUNT: BigNumberish = ethers.parseEther("1000");
      // Buy tokens first
      await token.connect(dex).transfer(user1.address, BUY_AMOUNT);

      // Try to sell everything immediately
      const user1Balance = await token.balanceOf(user1.address);
      await token.connect(user1).transfer(dex.address, user1Balance);

      const tokenBalanceMinusPreviousBuy = (await token.balanceOf(token.getAddress())) - ethers.parseEther("500");

      // Check that unvested tokens were forfeited
      const expectedForfeited = (BUY_AMOUNT * BigInt(LOCK_PERCENTAGE)) / 100n;
      expect(tokenBalanceMinusPreviousBuy).to.be.closeTo(expectedForfeited, ethers.parseEther("1"));
    });
  });

  describe("Vesting", function () {
    const BUY_AMOUNT: BigNumberish = ethers.parseEther("1000");

    beforeEach(async function () {
      await token.connect(treasury).transfer(dex.address, ethers.parseEther("1000000"));
      await token.setDexPair(dex.address, true);
      await token.connect(dex).transfer(user1.address, BUY_AMOUNT);
    });

    it("Should vest linearly over 7 days", async function () {
      const initialLocked: BigNumberish = await token.userTotalLocked(user1.address);

      // Check at 3.5 days (50% vested)
      await advanceTime(VESTING_DURATION / 2);
      const halfVested: BigNumberish = await token.userTotalUnvested(user1.address);
      expect(halfVested).to.be.closeTo(initialLocked / 2n, ethers.parseEther("1"));

      // Check at 7 days (fully vested)
      await advanceTime(VESTING_DURATION / 2);
      const fullyVested: BigNumberish = await token.userTotalUnvested(user1.address);
      expect(fullyVested).to.equal(0);
    });
  });

  describe("Schedule Merging", function () {
    const MERGE_WINDOW = 24 * 60 * 60; // 1 day
    const FIRST_BUY = ethers.parseEther("1000");
    const SECOND_BUY = ethers.parseEther("2000");

    beforeEach(async function () {
      // Fund DEX
      await token.connect(treasury).transfer(dex.address, ethers.parseEther("1000000"));
      await token.setDexPair(dex.address, true);
    });

    it("Should merge schedules if second buy is within 1 day", async function () {
      // First buy
      await token.connect(dex).transfer(user1.address, FIRST_BUY);
      let scheduleCount = await token.getScheduleCount(user1.address);
      expect(scheduleCount).to.equal(1);

      // Second buy within 1 day
      await advanceTime(MERGE_WINDOW / 2);
      await token.connect(dex).transfer(user1.address, SECOND_BUY);

      // The contract should have merged the new locked tokens into the same schedule
      scheduleCount = await token.getScheduleCount(user1.address);
      expect(scheduleCount).to.equal(1); // still 1 schedule after merge

      // Check that the locked amount has increased
      const totalLocked = await token.userTotalLocked(user1.address);
      const expectedLocked = ((FIRST_BUY + SECOND_BUY) * BigInt(LOCK_PERCENTAGE)) / 100n;
      expect(totalLocked).to.equal(expectedLocked);
    });

    it("Should not merge schedules if second buy is after 1 day", async function () {
      // First buy
      await token.connect(dex).transfer(user1.address, FIRST_BUY);

      // Wait slightly more than MERGE_WINDOW
      await advanceTime(MERGE_WINDOW + 1);

      // Second buy
      await token.connect(dex).transfer(user1.address, SECOND_BUY);

      // Now there should be 2 schedules
      const scheduleCount = await token.getScheduleCount(user1.address);
      expect(scheduleCount).to.equal(2);
    });

    it("Should merge oldest schedules after exceeding max schedules", async function () {
      await token.setMergeWindow(60);
      const MERGE_WINDOW = 60;
      const SMALL_BUY = ethers.parseEther("2");
      // Repeatedly buy to create schedules
      for (const _ of Array(MAX_SCHEDULES)) {
        // Force each buy to happen more than MERGE_WINDOW apart so no auto-merge
        await advanceTime(MERGE_WINDOW + 1);
        await token.connect(dex).transfer(user1.address, SMALL_BUY);
      }

      let countBefore = await token.getScheduleCount(user1.address);
      // We expect that the contract will merge full vested schedules, so we'll never hit 30
      expect(countBefore).to.equal(MAX_SCHEDULES);

      // Now do one more buy, which triggers merges
      await advanceTime(MERGE_WINDOW + 1);
      await token.connect(dex).transfer(user1.address, SMALL_BUY);

      const countAfter = await token.getScheduleCount(user1.address);
      // We expect that after adding the new schedule, the contract merges the oldest two,
      // so total schedules remain = MAX_SCHEDULES
      expect(countAfter).to.equal(MAX_SCHEDULES);
    });

    it("Should transfer as normal if amount is less than minimum vest amount", async function () {
      // Transfer to user1 so she has a small balance
      await token.connect(treasury).transfer(user1.address, 50);

      // Alice -> Bob with only 50 tokens
      await token.connect(user1).transfer(user2.address, 50);

      expect(await token.balanceOf(user2.address)).to.equal(50);
      // No schedules should have been created
      expect(await token.getScheduleCount(user2.address)).to.equal(0);
    });
  });

  describe("Merkle Claims", function () {
    const CLAIM_AMOUNT: BigNumberish = ethers.parseEther("100");
    let merkleRoot: string;
    let user1Proof: string[];

    beforeEach(async function () {
      // Generate Merkle tree with claims
      const claims: MerkleTreeClaim[] = [
        { index: 0, account: user1.address, amount: CLAIM_AMOUNT },
        { index: 1, account: user2.address, amount: CLAIM_AMOUNT * 2n },
      ];

      const { root, proofs } = generateMerkleTreeAndProofs(claims);
      merkleRoot = root;
      user1Proof = proofs[0];

      // Set Merkle root and fund contract
      await token.setMerkleRoot(merkleRoot);
      await token.connect(treasury).transfer(await token.getAddress(), CLAIM_AMOUNT * 10n);
    });

    it("Should allow valid claims", async function () {
      await token.connect(user1).claim(0, user1.address, CLAIM_AMOUNT, user1Proof);

      expect(await token.balanceOf(user1.address)).to.equal(CLAIM_AMOUNT);
      expect(await token.hasClaimed(user1.address)).to.be.true;
    });

    it("Should prevent double claims", async function () {
      await token.connect(user1).claim(0, user1.address, CLAIM_AMOUNT, user1Proof);

      await expect(
        token.connect(user1).claim(0, user1.address, CLAIM_AMOUNT, user1Proof)
      ).to.be.revertedWithCustomError(token, "AlreadyClaimed");
    });

    it("Should revert if user passes invalid amount in merkle proof", async function () {
      const fakeAmount = CLAIM_AMOUNT * 2n;
      await expect(token.connect(user1).claim(0, user1.address, fakeAmount, user1Proof)).to.be.revertedWithCustomError(
        token,
        "InvalidMerkleProof"
      );
    });

    it("Should revert if user passes a random proof", async function () {
      await expect(token.connect(user1).claim(999, user1.address, CLAIM_AMOUNT, [])).to.be.revertedWithCustomError(
        token,
        "InvalidMerkleProof"
      );
    });
  });
});
