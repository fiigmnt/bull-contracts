// DeployVestingERC20Module.ts
import { buildModule } from "@nomicfoundation/hardhat-ignition/modules";

// Provide defaults if none are passed in
const DEFAULT_NAME = "MyToken";
const DEFAULT_SYMBOL = "MTK";
// If you want to use BigInt for large numbers, you can do so
const DEFAULT_INITIAL_SUPPLY: bigint = 1_000_000n;

const TREASURY_ADDRESS = "0x02aC1EB59440C29f44C9fDfB8369B423e1dbedb5";

const VestingERC20Module = buildModule("VestingERC20Module", (m) => {
  // Fetch parameters from the Hardhat config or use defaults
  const tokenName = m.getParameter("tokenName", DEFAULT_NAME);
  const tokenSymbol = m.getParameter("tokenSymbol", DEFAULT_SYMBOL);
  const initialSupply = m.getParameter("initialSupply", DEFAULT_INITIAL_SUPPLY);
  const treasuryAddress = m.getParameter("treasuryAddress", TREASURY_ADDRESS);

  // This is where you deploy the contract by calling its constructor
  // with the required parameters
  const vestingToken = m.contract("VestingERC20", [
    tokenName,       // _name
    tokenSymbol,     // _symbol
    initialSupply,   // _initialSupply
    treasuryAddress  // _treasuryAddress
  ]);

  return { vestingToken };
});

export default VestingERC20Module;
