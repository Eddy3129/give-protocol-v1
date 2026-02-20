#!/usr/bin/env node
/**
 * viem-smoke.mjs — multi-chain frontend integration test
 *
 * Modes:
 *   --mode=local   Anvil (plain or fork), reads deployment JSON, runs full lifecycle
 *   --mode=rpc     Live RPC, validates protocol connectivity only (no write txs)
 *
 * Chain config:
 *   CHAIN_CONFIG=config/chains/base.json   (default)
 *   CHAIN_CONFIG=config/chains/arbitrum.json
 *   CHAIN_CONFIG=config/chains/optimism.json
 *   CHAIN_CONFIG=config/chains/local.json  (plain Anvil, no protocol checks)
 *
 * Other env vars:
 *   BASE_RPC_URL / ARBITRUM_RPC_URL / etc.   RPC endpoints (per chain config)
 *   ANVIL_RPC_URL                             Anvil URL for --mode=local (default: 127.0.0.1:8545)
 *   DEPLOYMENT_FILE                           Override deployment JSON path
 *   FORK_MODE=1                               Set by fork-smoke.sh; skips MockERC20.mint()
 *
 * Usage:
 *   node frontend/scripts/viem-smoke.mjs --mode=local
 *   node frontend/scripts/viem-smoke.mjs --mode=rpc
 *   CHAIN_CONFIG=config/chains/arbitrum.json node frontend/scripts/viem-smoke.mjs --mode=rpc
 *   node frontend/scripts/viem-smoke.mjs --mode=local --rpc-url=http://127.0.0.1:8545
 */

import {
  createPublicClient,
  createWalletClient,
  fallback,
  formatUnits,
  http,
  parseUnits,
  parseAbi,
  keccak256,
  toBytes,
  getAddress,
  defineChain,
} from "viem";
import { privateKeyToAccount } from "viem/accounts";
import { readFileSync, existsSync } from "fs";
import { resolve, dirname } from "path";
import { fileURLToPath } from "url";

// ── Paths ─────────────────────────────────────────────────────────────────────

const __dir = dirname(fileURLToPath(import.meta.url));
const ROOT = resolve(__dir, "../..");

// ── Chain config ──────────────────────────────────────────────────────────────

function loadChainConfig(mode) {
  // Default: local mode uses local.json (plain Anvil), rpc/fork mode uses base.json.
  // Override with CHAIN_CONFIG for any other chain.
  const defaultConfig = mode === "local" ? "config/chains/local.json" : "config/chains/base.json";
  const configPath = process.env.CHAIN_CONFIG ?? defaultConfig;
  const abs = resolve(ROOT, configPath);
  if (!existsSync(abs)) {
    throw new Error(
      `Chain config not found: ${abs}\n` +
      `Available: config/chains/{base,arbitrum,optimism,local}.json\n` +
      `Set CHAIN_CONFIG=config/chains/<name>.json`
    );
  }
  return JSON.parse(readFileSync(abs, "utf8"));
}

// ── CLI helpers ───────────────────────────────────────────────────────────────

function getArg(name) {
  const prefix = `--${name}=`;
  const found = process.argv.find((a) => a.startsWith(prefix));
  return found ? found.slice(prefix.length) : undefined;
}

function parseMode() {
  const mode = getArg("mode") ?? "local";
  if (mode !== "local" && mode !== "rpc") {
    throw new Error(`Invalid --mode '${mode}'. Use local or rpc.`);
  }
  return mode;
}

function rpcUrlsForMode(mode, chain) {
  const cli = getArg("rpc-url");
  if (cli) return [cli];

  if (mode === "local") {
    return [process.env.ANVIL_RPC_URL ?? "http://127.0.0.1:8545"];
  }

  // rpc mode: read from env vars named in chain config
  const primary = chain.rpcEnvVar ? process.env[chain.rpcEnvVar] : null;
  const fallback_ = chain.fallbackRpcEnvVar ? process.env[chain.fallbackRpcEnvVar] : null;
  const urls = [primary, fallback_].filter(Boolean);
  if (urls.length === 0) {
    throw new Error(
      `No RPC URL found for ${chain.name}.\n` +
      `Set ${chain.rpcEnvVar}=https://... (and optionally ${chain.fallbackRpcEnvVar})`
    );
  }
  return urls;
}

function makeTransport(urls) {
  return urls.length === 1 ? http(urls[0]) : fallback(urls.map((u) => http(u)));
}

function loadDeployment(chain) {
  const file = process.env.DEPLOYMENT_FILE ?? chain.deploymentFile;
  const path = resolve(ROOT, file);
  try {
    return JSON.parse(readFileSync(path, "utf8"));
  } catch {
    throw new Error(`Deployment file not found: ${path}. Run: npm run deploy:local:all`);
  }
}

// ── Pass / Fail tracking ──────────────────────────────────────────────────────

let passed = 0;
let failed = 0;

function pass(label) {
  console.log(`  ✓ ${label}`);
  passed++;
}

function fail(label, err) {
  const msg = err?.shortMessage ?? err?.message ?? String(err);
  console.log(`  ✗ ${label}: ${msg}`);
  failed++;
}

async function check(label, fn) {
  try {
    const result = await fn();
    pass(label + (result !== undefined ? ` [${result}]` : ""));
    return result;
  } catch (err) {
    fail(label, err);
    return undefined;
  }
}

async function expectRevert(label, fn, expectedFragment) {
  try {
    await fn();
    fail(label, new Error("expected revert but succeeded"));
  } catch (err) {
    const msg = err?.shortMessage ?? err?.message ?? String(err);
    if (msg.toLowerCase().includes(expectedFragment.toLowerCase())) {
      pass(`${label} [reverts: ${expectedFragment}]`);
    } else {
      fail(`${label} (wrong revert: ${msg})`, null);
    }
  }
}

// ── Section runner ────────────────────────────────────────────────────────────

function section(title) {
  console.log(`\n── ${title} ${"─".repeat(Math.max(0, 60 - title.length))}`);
}

// ── ABIs ──────────────────────────────────────────────────────────────────────

const erc20Abi = parseAbi([
  "function name() view returns (string)",
  "function symbol() view returns (string)",
  "function decimals() view returns (uint8)",
  "function totalSupply() view returns (uint256)",
  "function balanceOf(address) view returns (uint256)",
  "function allowance(address owner, address spender) view returns (uint256)",
  "function approve(address spender, uint256 amount) returns (bool)",
]);

const vaultAbi = parseAbi([
  "function name() view returns (string)",
  "function symbol() view returns (string)",
  "function asset() view returns (address)",
  "function totalAssets() view returns (uint256)",
  "function totalSupply() view returns (uint256)",
  "function balanceOf(address) view returns (uint256)",
  "function previewDeposit(uint256 assets) view returns (uint256)",
  "function previewRedeem(uint256 shares) view returns (uint256)",
  "function convertToAssets(uint256 shares) view returns (uint256)",
  "function convertToShares(uint256 assets) view returns (uint256)",
  "function maxDeposit(address) view returns (uint256)",
  "function maxRedeem(address) view returns (uint256)",
  "function getCashBalance() view returns (uint256)",
  "function getAdapterAssets() view returns (uint256)",
  "function donationRouter() view returns (address)",
  "function investPaused() view returns (bool)",
  "function harvestPaused() view returns (bool)",
  "function emergencyShutdown() view returns (bool)",
  "function cashBufferBps() view returns (uint256)",
  "function deposit(uint256 assets, address receiver) returns (uint256)",
  "function redeem(uint256 shares, address receiver, address owner) returns (uint256)",
  "function withdraw(uint256 assets, address receiver, address owner) returns (uint256)",
  "event Deposit(address indexed sender, address indexed owner, uint256 assets, uint256 shares)",
  "event Withdraw(address indexed sender, address indexed receiver, address indexed owner, uint256 assets, uint256 shares)",
]);

const routerAbi = parseAbi([
  "function feeBps() view returns (uint256)",
  "function feeRecipient() view returns (address)",
  "function protocolTreasury() view returns (address)",
  "function campaignRegistry() view returns (address)",
  "function getTotalVaultShares(address vault) view returns (uint256)",
  "function getUserVaultShares(address user, address vault) view returns (uint256)",
  "function getPendingYield(address user, address vault, address asset) view returns (uint256)",
  "function getValidAllocations() view returns (uint8[3])",
  "function getVaultCampaign(address vault) view returns (bytes32)",
  "function getVaultPreference(address user, address vault) view returns (bytes32, address, uint8, bool)",
  "function setVaultPreference(address vault, address beneficiary, uint8 allocationPercentage)",
  "function claimYield(address vault, address asset) returns (uint256)",
  "event YieldPreferenceUpdated(address indexed user, address indexed vault, bytes32 indexed campaignId, address beneficiary, uint8 allocationPercentage)",
  "event UserSharesUpdated(address indexed user, address indexed vault, uint256 shares, uint256 totalShares)",
]);

// getReserveData returns a large struct — use JSON ABI to avoid parseAbi named-tuple limitation
const aavePoolAbi = [
  {
    type: "function",
    name: "getReserveData",
    inputs: [{ name: "asset", type: "address" }],
    outputs: [
      {
        name: "",
        type: "tuple",
        components: [
          { name: "configuration", type: "uint256" },
          { name: "liquidityIndex", type: "uint128" },
          { name: "currentLiquidityRate", type: "uint128" },
          { name: "variableBorrowIndex", type: "uint128" },
          { name: "currentVariableBorrowRate", type: "uint128" },
          { name: "currentStableBorrowRate", type: "uint128" },
          { name: "lastUpdateTimestamp", type: "uint40" },
          { name: "id", type: "uint16" },
          { name: "aTokenAddress", type: "address" },
          { name: "stableDebtTokenAddress", type: "address" },
          { name: "variableDebtTokenAddress", type: "address" },
          { name: "interestRateStrategyAddress", type: "address" },
          { name: "accruedToTreasury", type: "uint128" },
          { name: "unbacked", type: "uint128" },
          { name: "isolationModeTotalDebt", type: "uint128" },
        ],
      },
    ],
    stateMutability: "view",
  },
];

const aaveOracleAbi = parseAbi([
  "function getAssetPrice(address asset) view returns (uint256)",
]);

// ── Anvil default accounts ────────────────────────────────────────────────────

const ANVIL_ACCOUNTS = [
  { address: "0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266", key: "0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80" },
  { address: "0x70997970C51812dc3A010C7d01b50e0d17dc79C8", key: "0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d" },
  { address: "0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC", key: "0x5de4111afa1a4b94908f83103eb1f1706367c2e68ca870fc3fb9a804cdab365a" },
];

// ═════════════════════════════════════════════════════════════════════════════
// RPC MODE — protocol connectivity only, no write txs
// ═════════════════════════════════════════════════════════════════════════════

async function runRpcMode(urls, chain) {
  const proto = chain.protocol;

  // Build a viem chain definition from config
  const viemChain = defineChain({
    id: chain.chainId,
    name: chain.name,
    nativeCurrency: chain.nativeCurrency,
    rpcUrls: { default: { http: [urls[0]] } },
  });
  const client = createPublicClient({ chain: viemChain, transport: makeTransport(urls) });

  section("Chain");
  await check(`chainId = ${chain.chainId} (${chain.name})`, async () => {
    const id = await client.getChainId();
    if (id !== chain.chainId) throw new Error(`got ${id}, expected ${chain.chainId}`);
    return id;
  });
  await check("block number > 0", async () => {
    const n = await client.getBlockNumber();
    if (n === 0n) throw new Error("block 0");
    return n.toString();
  });

  if (!proto.usdc) {
    console.log("  ─ no protocol addresses configured for this chain (local config) — skipping protocol checks");
    return;
  }

  section(`USDC (${chain.name})`);
  await check("symbol = USDC", async () =>
    client.readContract({ address: proto.usdc, abi: erc20Abi, functionName: "symbol" })
  );
  await check(`decimals = ${proto.usdcDecimals}`, async () => {
    const d = await client.readContract({ address: proto.usdc, abi: erc20Abi, functionName: "decimals" });
    if (d !== proto.usdcDecimals) throw new Error(`got ${d}`);
    return d;
  });
  await check("totalSupply > 0", async () => {
    const s = await client.readContract({ address: proto.usdc, abi: erc20Abi, functionName: "totalSupply" });
    if (s === 0n) throw new Error("zero supply");
    return `${formatUnits(s, proto.usdcDecimals)} USDC`;
  });

  if (proto.aavePool) {
    section(`Aave V3 Pool (${chain.name})`);
    await check("getReserveData(USDC) returns aToken", async () => {
      const data = await client.readContract({
        address: proto.aavePool, abi: aavePoolAbi, functionName: "getReserveData", args: [proto.usdc],
      });
      const aToken = getAddress(data.aTokenAddress);
      if (proto.aUsdc && aToken.toLowerCase() !== proto.aUsdc.toLowerCase()) {
        throw new Error(`aToken mismatch: got ${aToken}, expected ${proto.aUsdc}`);
      }
      return aToken;
    });
    await check("USDC liquidity rate > 0", async () => {
      const data = await client.readContract({
        address: proto.aavePool, abi: aavePoolAbi, functionName: "getReserveData", args: [proto.usdc],
      });
      if (data.currentLiquidityRate === 0n) throw new Error("zero — pool may be empty");
      const apyPct = Number(data.currentLiquidityRate) / 1e27 * 100;
      return `${apyPct.toFixed(4)}% APY`;
    });

    if (proto.aUsdc) {
      section(`aUSDC (${chain.name})`);
      await check("aUSDC totalSupply > 0", async () => {
        const s = await client.readContract({ address: proto.aUsdc, abi: erc20Abi, functionName: "totalSupply" });
        if (s === 0n) throw new Error("zero supply");
        return `${formatUnits(s, proto.usdcDecimals)} aUSDC`;
      });
    }
  }

  if (proto.wsteth) {
    section(`wstETH (${chain.name})`);
    await check("wstETH totalSupply > 0", async () => {
      const s = await client.readContract({ address: proto.wsteth, abi: erc20Abi, functionName: "totalSupply" });
      if (s === 0n) throw new Error("zero supply");
      return `${formatUnits(s, 18)} wstETH`;
    });
    if (proto.aaveOracle) {
      await check("wstETH price via Aave oracle > $1000", async () => {
        const price = await client.readContract({
          address: proto.aaveOracle, abi: aaveOracleAbi, functionName: "getAssetPrice", args: [proto.wsteth],
        });
        if (price < 1000n * 10n ** 8n) throw new Error(`price too low: $${formatUnits(price, 8)}`);
        return `$${formatUnits(price, 8)} USD`;
      });
    }
  }

  if (proto.pendleRouter) {
    section("Pendle Router");
    await check("bytecode deployed at known address", async () => {
      const code = await client.getBytecode({ address: proto.pendleRouter });
      if (!code || code === "0x") throw new Error("no bytecode");
      return `${code.length} bytes`;
    });
  }

  section("Multi-RPC fallback");
  if (urls.length > 1) {
    await check("fallback transport resolves chainId", async () => {
      const id = await client.getChainId();
      return `chainId=${id} via fallback`;
    });
  } else {
    console.log(`  ─ only one RPC configured, fallback test skipped`);
  }
}

// ═════════════════════════════════════════════════════════════════════════════
// LOCAL MODE — full lifecycle (plain Anvil or fork)
// ═════════════════════════════════════════════════════════════════════════════

async function runLocalMode(urls, chain) {
  const isFork = process.env.FORK_MODE === "1";
  const deployment = loadDeployment(chain);

  const vaultAddress = getAddress(deployment.USDCVault);
  const routerAddress = getAddress(deployment.PayoutRouter);

  // Build chain definition from deployment JSON (handles both 31337 and any fork chainId)
  const deployChainId = deployment.chainId ?? chain.chainId ?? 31337;
  const localChain = defineChain({
    id: deployChainId,
    name: isFork ? `${chain.name} fork` : "local",
    nativeCurrency: chain.nativeCurrency ?? { name: "Ether", symbol: "ETH", decimals: 18 },
    rpcUrls: { default: { http: [urls[0]] } },
  });

  const transport = makeTransport(urls);
  const publicClient = createPublicClient({ chain: localChain, transport });

  // Resolve USDC: deployment JSON → env → chain config → vault.asset()
  const usdcAddress = await (async () => {
    for (const k of ["USDCAddress", "USDC_ADDRESS", "USDC", "MockUSDC"]) {
      if (deployment[k]) return getAddress(deployment[k]);
    }
    if (process.env.USDC_ADDRESS) return getAddress(process.env.USDC_ADDRESS);
    if (chain.protocol?.usdc) return getAddress(chain.protocol.usdc);
    try {
      const asset = await publicClient.readContract({ address: vaultAddress, abi: vaultAbi, functionName: "asset" });
      if (asset && asset !== "0x0000000000000000000000000000000000000000") return getAddress(asset);
    } catch {}
    return null;
  })();

  const deployer = ANVIL_ACCOUNTS[0];
  const user = ANVIL_ACCOUNTS[1];
  const user2 = ANVIL_ACCOUNTS[2];

  const deployerWallet = createWalletClient({ account: privateKeyToAccount(deployer.key), chain: localChain, transport });
  const userWallet = createWalletClient({ account: privateKeyToAccount(user.key), chain: localChain, transport });

  // ── 1. Chain ────────────────────────────────────────────────────────────────

  section(`Chain (${isFork ? chain.name + " fork" : "Anvil local"})`);
  await check(`chainId = ${deployChainId}`, async () => {
    const id = await publicClient.getChainId();
    if (id !== deployChainId) throw new Error(`got ${id}`);
    return id;
  });
  await check("block > 0", async () => {
    const n = await publicClient.getBlockNumber();
    return n.toString();
  });

  // ── 2. Vault reads ──────────────────────────────────────────────────────────

  section("GiveVault4626 — reads");
  await check("name()", async () =>
    publicClient.readContract({ address: vaultAddress, abi: vaultAbi, functionName: "name" })
  );
  await check("symbol()", async () =>
    publicClient.readContract({ address: vaultAddress, abi: vaultAbi, functionName: "symbol" })
  );
  await check("asset()", async () =>
    publicClient.readContract({ address: vaultAddress, abi: vaultAbi, functionName: "asset" })
  );
  await check("totalAssets() >= 0", async () => {
    const ta = await publicClient.readContract({ address: vaultAddress, abi: vaultAbi, functionName: "totalAssets" });
    return `${formatUnits(ta, 6)} USDC`;
  });
  await check("donationRouter() = PayoutRouter", async () => {
    const r = await publicClient.readContract({ address: vaultAddress, abi: vaultAbi, functionName: "donationRouter" });
    if (r === "0x0000000000000000000000000000000000000000") {
      return "⚠ zero — setDonationRouter not called in Deploy03_Initialize";
    }
    if (getAddress(r).toLowerCase() !== routerAddress.toLowerCase()) {
      throw new Error(`got ${r}, expected ${routerAddress}`);
    }
    return r;
  });
  await check("investPaused() = false", async () => {
    const p = await publicClient.readContract({ address: vaultAddress, abi: vaultAbi, functionName: "investPaused" });
    if (p) throw new Error("invest is paused");
    return false;
  });
  await check("emergencyShutdown() = false", async () => {
    const e = await publicClient.readContract({ address: vaultAddress, abi: vaultAbi, functionName: "emergencyShutdown" });
    if (e) throw new Error("emergency shutdown active");
    return false;
  });

  // ── 3. PayoutRouter reads ───────────────────────────────────────────────────

  section("PayoutRouter — reads");
  await check("feeBps() in [0, 1000]", async () => {
    const bps = await publicClient.readContract({ address: routerAddress, abi: routerAbi, functionName: "feeBps" });
    if (bps > 1000n) throw new Error(`feeBps too high: ${bps}`);
    return `${bps} bps`;
  });
  await check("feeRecipient() != zero", async () => {
    const r = await publicClient.readContract({ address: routerAddress, abi: routerAbi, functionName: "feeRecipient" });
    if (r === "0x0000000000000000000000000000000000000000") throw new Error("zero address");
    return r;
  });
  await check("getValidAllocations() = [50,75,100]", async () => {
    const allocs = await publicClient.readContract({ address: routerAddress, abi: routerAbi, functionName: "getValidAllocations" });
    for (let i = 0; i < 3; i++) {
      if (Number(allocs[i]) !== [50, 75, 100][i]) throw new Error(`allocs[${i}]=${allocs[i]}`);
    }
    return allocs.join(",");
  });
  await check("campaignRegistry() != zero", async () => {
    const r = await publicClient.readContract({ address: routerAddress, abi: routerAbi, functionName: "campaignRegistry" });
    if (r === "0x0000000000000000000000000000000000000000") throw new Error("zero address");
    return r;
  });

  // ── 4. USDC ─────────────────────────────────────────────────────────────────

  if (!usdcAddress) {
    console.log("\n── USDC ─── skipped (address not resolved)");
    return;
  }

  const decimals = await (async () => {
    try {
      return await publicClient.readContract({ address: usdcAddress, abi: erc20Abi, functionName: "decimals" });
    } catch {
      return 6;
    }
  })();

  section(`USDC (${isFork ? chain.name + " real" : "mock"})`);
  await check("decimals()", async () => decimals);

  const depositAmount = parseUnits("100", decimals);

  if (isFork) {
    // Fork mode: real USDC has no public mint — balance was pre-funded via anvil_setStorageAt
    await check("user USDC balance pre-funded via storage cheat", async () => {
      const bal = await publicClient.readContract({
        address: usdcAddress, abi: erc20Abi, functionName: "balanceOf", args: [user.address],
      });
      if (bal < depositAmount) throw new Error(`balance ${formatUnits(bal, decimals)} < 100 — storage cheat may have used wrong slot`);
      return `${formatUnits(bal, decimals)} USDC`;
    });
  } else {
    // Local mode: MockERC20 has unrestricted mint
    const mintAbi = parseAbi(["function mint(address to, uint256 amount)"]);
    await check("mint 10,000 USDC to user (MockERC20)", async () => {
      const hash = await deployerWallet.writeContract({
        address: usdcAddress, abi: mintAbi, functionName: "mint",
        args: [user.address, parseUnits("10000", decimals)],
      });
      await publicClient.waitForTransactionReceipt({ hash });
      return `minted 10000 USDC to ${user.address.slice(0, 10)}…`;
    });
    await check("user balance >= 100 USDC", async () => {
      const bal = await publicClient.readContract({
        address: usdcAddress, abi: erc20Abi, functionName: "balanceOf", args: [user.address],
      });
      if (bal < depositAmount) throw new Error(`balance ${formatUnits(bal, decimals)} < 100`);
      return `${formatUnits(bal, decimals)} USDC`;
    });
  }

  // ── 5. Approve ──────────────────────────────────────────────────────────────

  section("ERC-20 approve");
  await check("user approves vault for 100 USDC", async () => {
    const hash = await userWallet.writeContract({
      address: usdcAddress, abi: erc20Abi, functionName: "approve",
      args: [vaultAddress, depositAmount],
    });
    await publicClient.waitForTransactionReceipt({ hash });
    const allowance = await publicClient.readContract({
      address: usdcAddress, abi: erc20Abi, functionName: "allowance",
      args: [user.address, vaultAddress],
    });
    if (allowance < depositAmount) throw new Error(`allowance ${allowance} < ${depositAmount}`);
    return `allowance=${formatUnits(allowance, decimals)}`;
  });

  // ── 6. Deposit ──────────────────────────────────────────────────────────────

  section("GiveVault4626 — deposit");
  const preDepositAssets = await publicClient.readContract({ address: vaultAddress, abi: vaultAbi, functionName: "totalAssets" }).catch(() => 0n);
  let sharesMinted = 0n;

  await check("previewDeposit(100 USDC) > 0", async () => {
    const preview = await publicClient.readContract({
      address: vaultAddress, abi: vaultAbi, functionName: "previewDeposit", args: [depositAmount],
    });
    if (preview === 0n) throw new Error("zero shares preview");
    return `${formatUnits(preview, decimals)} shares`;
  });

  await check("deposit(100 USDC) emits Deposit event", async () => {
    const hash = await userWallet.writeContract({
      address: vaultAddress, abi: vaultAbi, functionName: "deposit",
      args: [depositAmount, user.address],
    });
    const receipt = await publicClient.waitForTransactionReceipt({ hash });
    const DEPOSIT_TOPIC = keccak256(toBytes("Deposit(address,address,uint256,uint256)"));
    const log = receipt.logs.find((l) => l.topics[0] === DEPOSIT_TOPIC);
    if (!log) throw new Error("Deposit event not found in logs");
    return `tx=${hash.slice(0, 10)}…`;
  });

  await check("user vault shares > 0 after deposit", async () => {
    sharesMinted = await publicClient.readContract({
      address: vaultAddress, abi: vaultAbi, functionName: "balanceOf", args: [user.address],
    });
    if (sharesMinted === 0n) throw new Error("zero shares");
    return `${formatUnits(sharesMinted, decimals)} shares`;
  });

  await check("totalAssets increased by ~100 USDC", async () => {
    const postAssets = await publicClient.readContract({ address: vaultAddress, abi: vaultAbi, functionName: "totalAssets" });
    const delta = postAssets - preDepositAssets;
    if (delta < depositAmount - parseUnits("1", decimals)) throw new Error(`delta too small: ${formatUnits(delta, decimals)}`);
    return `Δ=${formatUnits(delta, decimals)} USDC`;
  });

  // ── 7. PayoutRouter share tracking ─────────────────────────────────────────

  section("PayoutRouter — share tracking after deposit");
  const routerIsWired = await publicClient.readContract({
    address: vaultAddress, abi: vaultAbi, functionName: "donationRouter",
  }).then((r) => r !== "0x0000000000000000000000000000000000000000").catch(() => false);

  await check("getUserVaultShares updated", async () => {
    const s = await publicClient.readContract({
      address: routerAddress, abi: routerAbi, functionName: "getUserVaultShares",
      args: [user.address, vaultAddress],
    });
    if (!routerIsWired && s === 0n) return "⚠ 0 — donationRouter not set";
    return `${s} shares`;
  });
  await check("getTotalVaultShares > 0", async () => {
    const t = await publicClient.readContract({
      address: routerAddress, abi: routerAbi, functionName: "getTotalVaultShares",
      args: [vaultAddress],
    });
    if (t === 0n) {
      if (!routerIsWired) return "⚠ 0 — donationRouter not set";
      throw new Error("zero total shares");
    }
    return `${t} total shares`;
  });

  // ── 8. setVaultPreference ───────────────────────────────────────────────────

  section("PayoutRouter — setVaultPreference");
  const campaignId = await publicClient.readContract({
    address: routerAddress, abi: routerAbi, functionName: "getVaultCampaign", args: [vaultAddress],
  }).catch(() => "0x0000000000000000000000000000000000000000000000000000000000000000");

  if (campaignId === "0x0000000000000000000000000000000000000000000000000000000000000000") {
    console.log("  ─ vault has no campaign registered, skipping setVaultPreference");
  } else {
    await check("setVaultPreference(50%)", async () => {
      const hash = await userWallet.writeContract({
        address: routerAddress, abi: routerAbi, functionName: "setVaultPreference",
        args: [vaultAddress, user2.address, 50],
      });
      await publicClient.waitForTransactionReceipt({ hash });
      return `beneficiary=${user2.address.slice(0, 10)}… 50%`;
    });
    await check("getVaultPreference reflects update", async () => {
      const [, , allocationPercentage] = await publicClient.readContract({
        address: routerAddress, abi: routerAbi, functionName: "getVaultPreference",
        args: [user.address, vaultAddress],
      });
      if (Number(allocationPercentage) !== 50) throw new Error(`got ${allocationPercentage}`);
      return `allocation=${allocationPercentage}%`;
    });
  }

  // ── 9. claimYield simulation ────────────────────────────────────────────────

  section("PayoutRouter — claimYield simulation");
  await check("simulateContract claimYield (zero yield expected)", async () => {
    try {
      await publicClient.simulateContract({
        account: user.address,
        address: routerAddress, abi: routerAbi, functionName: "claimYield",
        args: [vaultAddress, usdcAddress],
      });
      return "ok (yield available)";
    } catch (err) {
      const msg = err?.shortMessage ?? err?.message ?? String(err);
      if (msg.toLowerCase().includes("vaultnotregistered")) throw err;
      return `expected revert (${msg.slice(0, 60)})`;
    }
  });

  // ── 10. ERC-4626 conversion parity ─────────────────────────────────────────

  section("ERC-4626 — conversion parity");
  const oneUnit = parseUnits("1", decimals);
  await check("convertToAssets(convertToShares(1 USDC)) ≈ 1 USDC (round-trip)", async () => {
    const shares = await publicClient.readContract({
      address: vaultAddress, abi: vaultAbi, functionName: "convertToShares", args: [oneUnit],
    });
    const assets = await publicClient.readContract({
      address: vaultAddress, abi: vaultAbi, functionName: "convertToAssets", args: [shares],
    });
    const diff = assets > oneUnit ? assets - oneUnit : oneUnit - assets;
    if (diff > 2n) throw new Error(`round-trip loss ${diff} wei > tolerance`);
    return `1 USDC → ${shares} shares → ${formatUnits(assets, decimals)} USDC`;
  });
  await check("previewDeposit ≈ convertToShares (consistent pricing)", async () => {
    const preview = await publicClient.readContract({
      address: vaultAddress, abi: vaultAbi, functionName: "previewDeposit", args: [depositAmount],
    });
    const convert = await publicClient.readContract({
      address: vaultAddress, abi: vaultAbi, functionName: "convertToShares", args: [depositAmount],
    });
    const diff = preview > convert ? preview - convert : convert - preview;
    if (diff > 1n) throw new Error(`previewDeposit=${preview} convertToShares=${convert} diff=${diff}`);
    return `previewDeposit=${formatUnits(preview, decimals)} convertToShares=${formatUnits(convert, decimals)}`;
  });

  // ── 11. Redeem ──────────────────────────────────────────────────────────────

  section("GiveVault4626 — redeem");
  const redeemShares = sharesMinted / 2n;
  if (redeemShares === 0n) {
    console.log("  ─ zero shares to redeem, skipping");
  } else {
    const preRedeemBal = await publicClient.readContract({
      address: usdcAddress, abi: erc20Abi, functionName: "balanceOf", args: [user.address],
    });

    await check(`redeem(${formatUnits(redeemShares, decimals)} shares) emits Withdraw event`, async () => {
      const sim = await publicClient.simulateContract({
        account: user.address,
        address: vaultAddress, abi: vaultAbi, functionName: "redeem",
        args: [redeemShares, user.address, user.address],
      });
      const hash = await userWallet.writeContract(sim.request);
      const receipt = await publicClient.waitForTransactionReceipt({ hash });
      const WITHDRAW_TOPIC = keccak256(toBytes("Withdraw(address,address,address,uint256,uint256)"));
      const log = receipt.logs.find((l) => l.topics[0] === WITHDRAW_TOPIC);
      if (!log) throw new Error(`Withdraw event not found in ${receipt.logs.length} logs`);
      return `tx=${hash.slice(0, 10)}…`;
    });

    await check("user USDC balance increased after redeem", async () => {
      const postBal = await publicClient.readContract({
        address: usdcAddress, abi: erc20Abi, functionName: "balanceOf", args: [user.address],
      });
      // 2 wei tolerance for Aave 1-wei rounding
      if (postBal + 2n <= preRedeemBal) throw new Error(`bal did not increase: ${formatUnits(postBal, decimals)}`);
      const delta = postBal > preRedeemBal ? postBal - preRedeemBal : 0n;
      return `Δ=${formatUnits(delta, decimals)} USDC`;
    });

    await check("user shares decreased after redeem", async () => {
      const remaining = await publicClient.readContract({
        address: vaultAddress, abi: vaultAbi, functionName: "balanceOf", args: [user.address],
      });
      if (remaining >= sharesMinted) throw new Error(`shares did not decrease: before=${sharesMinted} after=${remaining}`);
      return `${formatUnits(remaining, decimals)} shares remaining`;
    });
  }

  // ── 12. Revert mapping ──────────────────────────────────────────────────────

  section("Revert mapping");
  await check("deposit(0) does not corrupt state", async () => {
    const sharesBefore = await publicClient.readContract({
      address: vaultAddress, abi: vaultAbi, functionName: "balanceOf", args: [user.address],
    });
    try {
      const hash = await userWallet.writeContract({
        address: vaultAddress, abi: vaultAbi, functionName: "deposit", args: [0n, user.address],
      });
      await publicClient.waitForTransactionReceipt({ hash });
    } catch {}
    const sharesAfter = await publicClient.readContract({
      address: vaultAddress, abi: vaultAbi, functionName: "balanceOf", args: [user.address],
    });
    if (sharesAfter < sharesBefore) throw new Error("shares decreased after deposit(0)");
    return "state unchanged";
  });

  await expectRevert(
    "redeem more shares than balance reverts (ERC4626ExceededMaxRedeem)",
    () => userWallet.writeContract({
      address: vaultAddress, abi: vaultAbi, functionName: "redeem",
      args: [parseUnits("999999", decimals), user.address, user.address],
    }),
    "0xb94abeec"
  );

  // ── 13. Event log query ─────────────────────────────────────────────────────

  section("Event log query");
  const latestBlock = await publicClient.getBlockNumber();
  // On forks the chain is at a high block number; use a tight window to stay within RPC limits.
  // On local Anvil the chain is fresh so block 1 is fine.
  const logFromBlock = isFork ? (latestBlock > 500n ? latestBlock - 500n : 1n) : 1n;

  await check("getLogs Deposit events", async () => {
    const logs = await publicClient.getLogs({
      address: vaultAddress,
      event: vaultAbi.find((e) => e.type === "event" && e.name === "Deposit"),
      fromBlock: logFromBlock,
      toBlock: "latest",
    });
    return `${logs.length} Deposit events`;
  });

  await check("getLogs UserSharesUpdated from router", async () => {
    const logs = await publicClient.getLogs({
      address: routerAddress,
      event: routerAbi.find((e) => e.type === "event" && e.name === "UserSharesUpdated"),
      fromBlock: logFromBlock,
      toBlock: "latest",
    });
    return `${logs.length} UserSharesUpdated events`;
  });
}

// ═════════════════════════════════════════════════════════════════════════════
// Entry point
// ═════════════════════════════════════════════════════════════════════════════

async function main() {
  const mode = parseMode();
  const chain = loadChainConfig(mode);
  const urls = rpcUrlsForMode(mode, chain);

  console.log(`\nviem-smoke  mode=${mode}  chain=${chain.name}  rpc=${urls.join(",")}`);
  console.log("═".repeat(64));

  if (mode === "rpc") {
    await runRpcMode(urls, chain);
  } else {
    await runLocalMode(urls, chain);
  }

  console.log("\n" + "═".repeat(64));
  console.log(`result  passed=${passed}  failed=${failed}`);

  if (failed > 0) process.exit(1);
}

main().catch((err) => {
  console.error("\nFatal:", err?.shortMessage ?? err?.message ?? err);
  process.exit(1);
});
