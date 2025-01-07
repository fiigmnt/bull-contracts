// import { expect } from "chai";
// import { ethers } from "hardhat";
// import { time } from "@nomicfoundation/hardhat-network-helpers";
// import { SignerWithAddress } from "@nomiclabs/hardhat-ethers/signers";
// import { VestingToken } from "../typechain-types/contracts/VestingToken";
// import { Pool } from "@uniswap/v3-core/contracts/interfaces/IUniswapV3Pool.sol";
// import { FeeAmount } from "@uniswap/v3-sdk";
// import WETH9 from "../artifacts/@uniswap/v3-periphery/contracts/interfaces/external/IWETH9.sol/WETH9.json";
// import NonfungiblePositionManager from "../artifacts/@uniswap/v3-periphery/contracts/NonfungiblePositionManager.sol/NonfungiblePositionManager.json";
// import SwapRouter from "../artifacts/@uniswap/v3-periphery/contracts/SwapRouter.sol/SwapRouter.json";
// import UniswapV3Factory from "../artifacts/@uniswap/v3-core/contracts/UniswapV3Factory.sol/UniswapV3Factory.json";

// describe("VestingToken Uniswap V3 Integration", function () {
//   // Contract instances
//   let token: VestingToken;
//   let weth: any;
//   let factory: any;
//   let positionManager: any;
//   let router: any;
//   let pool: any;

//   // Signers
//   let owner: SignerWithAddress;
//   let treasury: SignerWithAddress;
//   let user1: SignerWithAddress;
//   let user2: SignerWithAddress;

//   // Constants
//   const INITIAL_SUPPLY: number = 1000000;
//   const SEVEN_DAYS: number = 7 * 24 * 60 * 60;
//   const ONE_DAY: number = 24 * 60 * 60;
//   const INITIAL_LIQUIDITY_TOKENS: bigint = ethers.parseEther("100000");
//   const INITIAL_LIQUIDITY_ETH: bigint = ethers.parseEther("100");
//   const FEE_TIER = 3000; // 0.3%

//   beforeEach(async function () {
//     // Get signers
//     [owner, treasury, user1, user2] = await ethers.getSigners();

//     // Deploy contracts
//     const WETH = await ethers.getContractFactory(WETH9.abi, WETH9.bytecode);
//     weth = await WETH.deploy();

//     const Factory = await ethers.getContractFactory(UniswapV3Factory.abi, UniswapV3Factory.bytecode);
//     factory = await Factory.deploy();

//     const PositionManager = await ethers.getContractFactory(NonfungiblePositionManager.abi, NonfungiblePositionManager.bytecode);
//     positionManager = await PositionManager.deploy(
//       factory.address,
//       weth.address,
//       // Assuming you have registry address - you may need to deploy this separately
//       ethers.ZeroAddress 
//     );

//     const Router = await ethers.getContractFactory(SwapRouter.abi, SwapRouter.bytecode);
//     router = await Router.deploy(
//       factory.address,
//       weth.address
//     );

//     // Deploy VestingToken
//     const VestingToken = await ethers.getContractFactory("VestingToken");
//     token = await VestingToken.deploy(
//       "Vesting Token",
//       "VEST",
//       INITIAL_SUPPLY,
//       treasury.address
//     ) as VestingToken;

//     // Create pool
//     await factory.createPool(
//       token.address,
//       weth.address,
//       FEE_TIER
//     );

//     const poolAddress = await factory.getPool(
//       token.address,
//       weth.address,
//       FEE_TIER
//     );
//     pool = await ethers.getContractAt("IUniswapV3Pool", poolAddress);

//     // Initialize pool with price
//     const initialPrice = encodePriceSqrt(1, 1500); // 1 ETH = 1500 tokens
//     await pool.initialize(initialPrice);

//     // Set pool in VestingToken
//     await token.setDexPair(poolAddress, true);

//     // Approve tokens
//     await token.connect(treasury).approve(positionManager.address, ethers.MaxUint256);
//     await weth.connect(treasury).deposit({ value: INITIAL_LIQUIDITY_ETH });
//     await weth.connect(treasury).approve(positionManager.address, ethers.MaxUint256);

//     // Add initial liquidity
//     const tokenAddress = token.address;
//     const wethAddress = weth.address;
//     const [token0, token1] = tokenAddress.toLowerCase() < wethAddress.toLowerCase()
//       ? [tokenAddress, wethAddress]
//       : [wethAddress, tokenAddress];

//     await positionManager.connect(treasury).mint({
//       token0,
//       token1,
//       fee: FEE_TIER,
//       tickLower: getMinTick(60),
//       tickUpper: getMaxTick(60),
//       amount0Desired: INITIAL_LIQUIDITY_TOKENS,
//       amount1Desired: INITIAL_LIQUIDITY_ETH,
//       amount0Min: 0,
//       amount1Min: 0,
//       recipient: treasury.address,
//       deadline: Math.floor(Date.now() / 1000) + 900
//     });
//   });

//   describe("Liquidity Setup", function () {
//     it("should have correct initial liquidity", async function () {
//       const slot0 = await pool.slot0();
//       expect(slot0.sqrtPriceX96).to.not.equal(0);
      
//       const liquidity = await pool.liquidity();
//       expect(liquidity).to.be.gt(0);
//     });
//   });

//   describe("Buying Through Uniswap V3", function () {
//     const ETH_TO_SPEND: bigint = ethers.parseEther("1");

//     async function buyTokens(user: SignerWithAddress): Promise<bigint> {
//       await weth.connect(user).deposit({ value: ETH_TO_SPEND });
//       await weth.connect(user).approve(router.address, ETH_TO_SPEND);

//       const params = {
//         tokenIn: weth.address,
//         tokenOut: token.address,
//         fee: FEE_TIER,
//         recipient: user.address,
//         deadline: Math.floor(Date.now() / 1000) + 900,
//         amountIn: ETH_TO_SPEND,
//         amountOutMinimum: 0,
//         sqrtPriceLimitX96: 0
//       };

//       const tx = await router.connect(user).exactInputSingle(params);
//       const receipt = await tx.wait();
      
//       // Find token transfer event to get actual amount
//       const transferEvent = receipt.events?.find(
//         e => e.event === "Transfer" && e.args?.to === user.address
//       );
//       return transferEvent?.args?.value || BigInt(0);
//     }

//     it("should lock 50% of tokens when buying", async function () {
//       const initialBalance = await token.balanceOf(user1.address);
//       const tokensBought = await buyTokens(user1);
      
//       const finalBalance = await token.balanceOf(user1.address);
//       const lockedAmount = await token.userTotalLocked(user1.address);
      
//       // User should receive 50% immediately
//       expect(finalBalance - initialBalance).to.equal(tokensBought / BigInt(2));
      
//       // 50% should be locked
//       expect(lockedAmount).to.equal(tokensBought / BigInt(2));
//     });
//   });

//   describe("Selling Through Uniswap V3", function () {
//     beforeEach(async function () {
//       // Buy tokens first
//       await buyTokens(user1);
//     });

//     async function sellTokens(
//       user: SignerWithAddress,
//       amount: bigint
//     ): Promise<void> {
//       await token.connect(user).approve(router.address, amount);

//       const params = {
//         tokenIn: token.address,
//         tokenOut: weth.address,
//         fee: FEE_TIER,
//         recipient: user.address,
//         deadline: Math.floor(Date.now() / 1000) + 900,
//         amountIn: amount,
//         amountOutMinimum: 0,
//         sqrtPriceLimitX96: 0
//       };

//       await router.connect(user).exactInputSingle(params);
//     }

//     it("should forfeit unvested tokens on early sell", async function () {
//       const initialContractBalance = await token.balanceOf(token.address);
//       const sellAmount = await token.balanceOf(user1.address);
      
//       // Sell after 2 days
//       await time.increase(2 * ONE_DAY);
//       await sellTokens(user1, sellAmount);

//       const finalContractBalance = await token.balanceOf(token.address);
//       expect(finalContractBalance).to.be.gt(initialContractBalance);
//     });

//     it("should allow full token sale after vesting", async function () {
//       const sellAmount = await token.balanceOf(user1.address);
      
//       // Wait for full vesting
//       await time.increase(SEVEN_DAYS);
//       await sellTokens(user1, sellAmount);
      
//       expect(await token.balanceOf(user1.address)).to.equal(0);
//     });
//   });

//   describe("Complex Trading Scenarios", function () {
//     it("should handle multiple buys and sells with vesting", async function () {
//       // First buy
//       await buyTokens(user1);
//       const firstBuyLocked = await token.userTotalLocked(user1.address);
      
//       // Wait 3 days
//       await time.increase(3 * ONE_DAY);
      
//       // Second buy
//       await buyTokens(user1);
//       const totalLocked = await token.userTotalLocked(user1.address);
      
//       // Should have merged schedules if within window
//       const scheduleCount = await token.getScheduleCount(user1.address);
//       expect(scheduleCount).to.lte(2);
      
//       // Partial sell
//       const balance = await token.balanceOf(user1.address);
//       await sellTokens(user1, balance / BigInt(2));
      
//       // Verify remaining balance and vesting
//       const finalBalance = await token.balanceOf(user1.address);
//       const remainingLocked = await token.userTotalLocked(user1.address);
      
//       expect(finalBalance).to.be.gt(0);
//       expect(remainingLocked).to.be.gt(0);
//     });
//   });
// });

// // Helper functions for ticks
// function getMinTick(tickSpacing: number): number {
//   return Math.ceil(-887272 / tickSpacing) * tickSpacing;
// }

// function getMaxTick(tickSpacing: number): number {
//   return Math.floor(887272 / tickSpacing) * tickSpacing;
// }