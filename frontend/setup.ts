import {
  createPublicClient,
  createWalletClient,
  createTestClient,
  getAddress,
  http,
} from "viem";
import { privateKeyToAccount } from "viem/accounts";
import { localhost, mainnet } from "viem/chains";
import * as dotenv from "dotenv";
import * as fs from "fs";
import * as path from "path";
import { execSync } from "child_process";

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
const rpcUrl =
  process.env.TENDERLY_VIRTUAL_TESTNET_RPC ||
  process.env.RPC_URL ||
  process.env.BASE_RPC_URL ||
  "http://127.0.0.1:8545";

const configuredChainId = Number(
  process.env.CHAIN_ID ||
    (rpcUrl.includes("127.0.0.1") ||
    rpcUrl.includes("localhost") ||
    rpcUrl.includes("buildbear") ||
    rpcUrl.includes("anvil")
      ? "31337"
      : "8453"),
);

const chain = configuredChainId === 31337 ? anvil : base;

// 2. Setup Viem Clients
// Signer priority:
// 1) PRIVATE_KEY
// 2) CAST_ACCOUNT alias (resolved via `cast wallet address --account <alias>`)
// 3) ACCOUNT_ADDRESS
// 4) Local Anvil default private key fallback
type WalletSigner = ReturnType<typeof privateKeyToAccount> | `0x${string}`;

function resolveWalletSigner(): WalletSigner {
  if (process.env.PRIVATE_KEY) {
    const privateKey = process.env.PRIVATE_KEY;
    return privateKeyToAccount(
      privateKey.startsWith("0x")
        ? (privateKey as `0x${string}`)
        : (`0x${privateKey}` as `0x${string}`),
    );
  }

  if (process.env.CAST_ACCOUNT) {
    const accountAlias = process.env.CAST_ACCOUNT;
    try {
      const resolved = execSync(
        `cast wallet address --account ${accountAlias}`,
        {
          encoding: "utf-8",
        },
      ).trim();
      return getAddress(resolved as `0x${string}`);
    } catch (error) {
      throw new Error(
        `Failed to resolve CAST_ACCOUNT='${accountAlias}'. Ensure cast is installed and account exists. ${String(error)}`,
      );
    }
  }

  if (process.env.ACCOUNT_ADDRESS) {
    return getAddress(process.env.ACCOUNT_ADDRESS as `0x${string}`);
  }

  const fallbackPrivateKey =
    "0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80";
  return privateKeyToAccount(fallbackPrivateKey as `0x${string}`);
}

const account = resolveWalletSigner();
export const signerAddress =
  typeof account === "string" ? account : getAddress(account.address);

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
  mode: "anvil",
});

// 3. Load Dynamic Deployments
// e.g. "anvil-latest.json" or "base-mainnet-latest.json"
const networkName = configuredChainId === 31337 ? "anvil" : "base-mainnet";
const deploymentsPath = path.join(
  __dirname,
  `../deployments/${networkName}-latest.json`,
);

if (!fs.existsSync(deploymentsPath)) {
  throw new Error(
    `Deployments file not found: ${deploymentsPath}. Did you run deploy_local_all.sh?`,
  );
}

export const deployments = JSON.parse(
  fs.readFileSync(deploymentsPath, "utf-8"),
);

// 4. Load common ABIs
export function getAbi(contractName: string) {
  const artifactPath = path.join(
    __dirname,
    `../out/${contractName}.sol/${contractName}.json`,
  );
  if (!fs.existsSync(artifactPath)) {
    throw new Error(
      `ABI not found for ${contractName}. Did you run forge build?`,
    );
  }
  const artifact = JSON.parse(fs.readFileSync(artifactPath, "utf-8"));
  return artifact.abi;
}
