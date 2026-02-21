import { createPublicClient, createWalletClient, createTestClient, http, custom } from "viem";
import { privateKeyToAccount } from "viem/accounts";
import { localhost, mainnet } from "viem/chains";
import * as dotenv from "dotenv";
import * as fs from "fs";
import * as path from "path";

// Load protocol .env from parent dir
dotenv.config({ path: path.join(__dirname, "../.env") });

// Define Base chain because viem base is standard but we might want to override RPC
const base = {
  ...mainnet,
  id: 8453,
  name: "Base",
};

const anvil = {
  ...localhost,
  id: 31337,
};

// 1. Get RPC from environment
const rpcUrl = process.env.TENDERLY_VIRTUAL_TESTNET_RPC || process.env.RPC_URL || process.env.BASE_RPC_URL || "http://127.0.0.1:8545";
const chainId = 8453; // Tenderly usually forks a specific chain ID, but standard Base is 8453
const chain = base;

// 2. Setup Viem Clients
// Default private key for local Anvil index 0 (0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80)
const pk = process.env.PRIVATE_KEY || "0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80";
const account = privateKeyToAccount(pk.startsWith("0x") ? pk as `0x${string}` : `0x${pk}`);

export const publicClient = createPublicClient({
  chain,
  transport: http(rpcUrl),
});

export const walletClient = createWalletClient({
  account,
  chain,
  transport: http(rpcUrl),
});

// For time traveling on local/fork testnets
export const testClient = createTestClient({
  chain,
  transport: http(rpcUrl),
  mode: "anvil"
});

// 3. Load Dynamic Deployments
// e.g. "anvil-latest.json" or "base-mainnet-latest.json"
const networkName = rpcUrl.includes("127.0.0.1") || rpcUrl.includes("localhost") ? "anvil" : "base-mainnet";
const deploymentsPath = path.join(__dirname, `../deployments/${networkName}-latest.json`);

if (!fs.existsSync(deploymentsPath)) {
  throw new Error(`Deployments file not found: ${deploymentsPath}. Did you run deploy_local_all.sh?`);
}

export const deployments = JSON.parse(fs.readFileSync(deploymentsPath, "utf-8"));

// 4. Load common ABIs
export function getAbi(contractName: string) {
  const artifactPath = path.join(__dirname, `../out/${contractName}.sol/${contractName}.json`);
  if (!fs.existsSync(artifactPath)) {
    throw new Error(`ABI not found for ${contractName}. Did you run forge build?`);
  }
  const artifact = JSON.parse(fs.readFileSync(artifactPath, "utf-8"));
  return artifact.abi;
}
