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
  process.env.RPC_URL || process.env.BASE_RPC_URL || "http://127.0.0.1:8545";

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
// 2) ACCOUNT_ADDRESS
// 3) Local Anvil default private key fallback
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
// Priority:
// 1) DEPLOYMENTS_FILE (explicit path)
// 2) DEPLOYMENT_NETWORK (e.g. anvil, base-mainnet)
// 3) chain-id heuristic fallback
const resolvedDeploymentsFile = process.env.DEPLOYMENTS_FILE;
const resolvedDeploymentNetwork = process.env.DEPLOYMENT_NETWORK;
if (!resolvedDeploymentsFile && !resolvedDeploymentNetwork) {
  throw new Error(
    "E2E requires explicit deployment artifact selection. Set DEPLOYMENT_NETWORK or DEPLOYMENTS_FILE.",
  );
}
const networkName =
  resolvedDeploymentNetwork ||
  (configuredChainId === 31337 ? "anvil" : "base-mainnet");
const deploymentsPath = resolvedDeploymentsFile
  ? path.isAbsolute(resolvedDeploymentsFile)
    ? resolvedDeploymentsFile
    : path.join(__dirname, "..", resolvedDeploymentsFile)
  : path.join(__dirname, `../deployments/${networkName}-latest.json`);

if (!fs.existsSync(deploymentsPath)) {
  throw new Error(
    `Deployments file not found: ${deploymentsPath}. Did you run deploy_local_all.sh?`,
  );
}

export const deployments = JSON.parse(
  fs.readFileSync(deploymentsPath, "utf-8"),
);

// 4. Load common artifacts
function getArtifact(contractName: string) {
  const artifactPath = path.join(
    __dirname,
    `../out/${contractName}.sol/${contractName}.json`,
  );
  if (!fs.existsSync(artifactPath)) {
    throw new Error(
      `ABI not found for ${contractName}. Did you run forge build?`,
    );
  }
  return JSON.parse(fs.readFileSync(artifactPath, "utf-8"));
}

export function getAbi(contractName: string) {
  const artifact = getArtifact(contractName);
  return artifact.abi;
}

export function getBytecode(contractName: string): `0x${string}` {
  const artifact = getArtifact(contractName);
  if (!artifact.bytecode?.object) {
    throw new Error(
      `Bytecode not found for ${contractName}. Did you run forge build?`,
    );
  }

  const bytecode = artifact.bytecode.object as string;
  return (
    bytecode.startsWith("0x") ? bytecode : `0x${bytecode}`
  ) as `0x${string}`;
}
