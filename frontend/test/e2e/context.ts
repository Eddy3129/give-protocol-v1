import { formatUnits, getAddress, parseUnits } from "viem";
import { privateKeyToAccount } from "viem/accounts";
import {
  deployments,
  getAbi,
  getBytecode,
  publicClient,
  signerAddress,
  testClient,
  walletClient,
} from "../../setup";

export const DEPOSIT_AMOUNT = parseUnits("100", 6);
export const SECTION_KEYS = [
  "0",
  "1",
  "2",
  "3",
  "4",
  "5",
  "6",
  "7",
  "8",
  "9",
  "10",
] as const;

export type SectionKey = (typeof SECTION_KEYS)[number];

const adminAccount = walletClient.account;
if (!adminAccount) {
  throw new Error(
    "walletClient.account is undefined. Configure PRIVATE_KEY in environment.",
  );
}

function requirePrivateKeyFromEnv(
  key: string,
  fallbackKey?: string,
  strictRequired = false,
): `0x${string}` {
  const primary = process.env[key];
  const fallback = fallbackKey ? process.env[fallbackKey] : undefined;
  const raw = primary || fallback;
  if (!raw) {
    throw new Error(
      `Missing ${key}${fallbackKey ? ` (or ${fallbackKey})` : ""}. Configure it in environment for frontend E2E tests.`,
    );
  }

  if (strictRequired && !primary) {
    throw new Error(
      `Strict E2E requires explicit ${key}; fallback keys are not allowed in strict mode.`,
    );
  }

  return raw.startsWith("0x")
    ? (raw as `0x${string}`)
    : (`0x${raw}` as `0x${string}`);
}

const userPrivateKey = requirePrivateKeyFromEnv(
  "USER_PRIVATE_KEY",
  undefined,
  true,
);
const outsiderPrivateKey = requirePrivateKeyFromEnv(
  "OUTSIDER_PRIVATE_KEY",
  "USER_PRIVATE_KEY",
  true,
);
const ngoPrivateKey = requirePrivateKeyFromEnv(
  "NGO_PRIVATE_KEY",
  "PRIVATE_KEY",
  true,
);

export type E2EContext = {
  adminAccount: typeof adminAccount;
  adminAddress: `0x${string}`;
  userAccount: ReturnType<typeof privateKeyToAccount>;
  ngoAccount: ReturnType<typeof privateKeyToAccount>;
  outsiderAccount: ReturnType<typeof privateKeyToAccount>;
  chainId: number;
  isFork: boolean;
  sectionDone: Set<string>;
  aclManagerAddress: `0x${string}`;
  strategyRegistryAddress: `0x${string}`;
  campaignRegistryAddress: `0x${string}`;
  campaignVaultFactoryAddress: `0x${string}`;
  payoutRouterAddress: `0x${string}`;
  usdcAddress: `0x${string}`;
  baseVaultAddress: `0x${string}`;
  campaignId?: `0x${string}`;
  campaignVaultAddress?: `0x${string}`;
  mintedShares: bigint;
  yieldProfit: bigint;
  harvestBlockNumber?: bigint;
  hasCampaignAdminRole: boolean;
  hasCampaignCuratorRole: boolean;
  campaignSubmitted: boolean;
  campaignApproved: boolean;
  fundedDepositFlowReady: boolean;
};

export const ctx: E2EContext = {
  adminAccount,
  adminAddress: signerAddress,
  userAccount: privateKeyToAccount(
    userPrivateKey.startsWith("0x")
      ? (userPrivateKey as `0x${string}`)
      : (`0x${userPrivateKey}` as `0x${string}`),
  ),
  ngoAccount: privateKeyToAccount(
    ngoPrivateKey.startsWith("0x")
      ? (ngoPrivateKey as `0x${string}`)
      : (`0x${ngoPrivateKey}` as `0x${string}`),
  ),
  outsiderAccount: privateKeyToAccount(
    outsiderPrivateKey.startsWith("0x")
      ? (outsiderPrivateKey as `0x${string}`)
      : (`0x${outsiderPrivateKey}` as `0x${string}`),
  ),
  chainId: 31337,
  isFork: false,
  sectionDone: new Set<string>(),
  aclManagerAddress: "0x0000000000000000000000000000000000000000",
  strategyRegistryAddress: "0x0000000000000000000000000000000000000000",
  campaignRegistryAddress: "0x0000000000000000000000000000000000000000",
  campaignVaultFactoryAddress: "0x0000000000000000000000000000000000000000",
  payoutRouterAddress: "0x0000000000000000000000000000000000000000",
  usdcAddress: "0x0000000000000000000000000000000000000000",
  baseVaultAddress: "0x0000000000000000000000000000000000000000",
  mintedShares: 0n,
  yieldProfit: 0n,
  hasCampaignAdminRole: false,
  hasCampaignCuratorRole: false,
  campaignSubmitted: false,
  campaignApproved: false,
  fundedDepositFlowReady: false,
};

export async function initContext(): Promise<void> {
  ctx.chainId = await publicClient.getChainId();
  ctx.isFork = ctx.chainId !== 31337;

  ctx.aclManagerAddress = getAddress(deployments.ACLManager);
  ctx.strategyRegistryAddress = getAddress(deployments.StrategyRegistry);
  ctx.campaignRegistryAddress = getAddress(deployments.CampaignRegistry);
  ctx.campaignVaultFactoryAddress = getAddress(
    deployments.CampaignVaultFactory,
  );
  ctx.payoutRouterAddress = getAddress(deployments.PayoutRouter);
  ctx.usdcAddress = getAddress(
    deployments.USDCAddress || deployments.USDC || deployments.MockERC20,
  );
  ctx.baseVaultAddress = getAddress(deployments.USDCVault);

  ctx.hasCampaignAdminRole = (await publicClient.readContract({
    address: ctx.aclManagerAddress,
    abi: getAbi("ACLManager"),
    functionName: "hasRole",
    args: [deployments.ROLE_CAMPAIGN_ADMIN as `0x${string}`, ctx.adminAddress],
  })) as boolean;

  ctx.hasCampaignCuratorRole = (await publicClient.readContract({
    address: ctx.aclManagerAddress,
    abi: getAbi("ACLManager"),
    functionName: "hasRole",
    args: [
      deployments.ROLE_CAMPAIGN_CURATOR as `0x${string}`,
      ctx.adminAddress,
    ],
  })) as boolean;

  try {
    const existingCampaignId = (await publicClient.readContract({
      address: ctx.payoutRouterAddress,
      abi: getAbi("PayoutRouter"),
      functionName: "getVaultCampaign",
      args: [ctx.baseVaultAddress],
    })) as `0x${string}`;

    if (existingCampaignId && existingCampaignId !== "0x".padEnd(66, "0")) {
      ctx.campaignId = existingCampaignId;
      ctx.campaignVaultAddress = ctx.baseVaultAddress;
    }
  } catch {
    ctx.campaignVaultAddress = ctx.baseVaultAddress;
  }
}

export function markSectionDone(section: SectionKey, label: string): void {
  ctx.sectionDone.add(section);
  console.log(`[checkpoint] ✅ Section ${section} done — ${label}`);
}

export function requireOrSkip(condition: boolean, message: string): boolean {
  if (condition) return true;
  throw new Error(`[strict] ${message}`);
}

export function isZeroBytes32(value?: `0x${string}`): boolean {
  return !value || value.toLowerCase() === `0x${"0".repeat(64)}`;
}

export function getFirstLogArgs<T>(logs: unknown[]): T {
  return (logs[0] as { args: T }).args;
}

export function classifyE2EError(error: unknown): {
  source: "rpc" | "contract-revert" | "viem" | "unknown";
  message: string;
} {
  const text = String(error ?? "");
  const lowered = text.toLowerCase();

  if (
    lowered.includes("rpc request failed") ||
    lowered.includes("unlocked account") ||
    lowered.includes("lack of funds") ||
    lowered.includes("eth_sendtransaction") ||
    lowered.includes("eth_sendrawtransaction")
  ) {
    return { source: "rpc", message: text };
  }

  if (
    lowered.includes("revert") ||
    lowered.includes("execution reverted") ||
    lowered.includes("contractfunctionrevertederror") ||
    lowered.includes("returned no data")
  ) {
    return { source: "contract-revert", message: text };
  }

  if (lowered.includes("viem@") || lowered.includes("contractfunction")) {
    return { source: "viem", message: text };
  }

  return { source: "unknown", message: text };
}

export async function ensureUserHasUsdc(minAmount: bigint): Promise<boolean> {
  const erc20Abi = getAbi("IERC20");

  const userBal = (await publicClient.readContract({
    address: ctx.usdcAddress,
    abi: erc20Abi,
    functionName: "balanceOf",
    args: [ctx.userAccount.address],
  })) as bigint;

  if (userBal >= minAmount) return true;

  const adminBal = (await publicClient.readContract({
    address: ctx.usdcAddress,
    abi: erc20Abi,
    functionName: "balanceOf",
    args: [ctx.adminAddress],
  })) as bigint;

  if (adminBal < minAmount) {
    console.log(
      `[funding] Skipping funded flow: user=${formatUnits(userBal, 6)} USDC, admin=${formatUnits(adminBal, 6)} USDC`,
    );
    return false;
  }

  const transferHash = await walletClient.writeContract({
    account: ctx.adminAccount,
    address: ctx.usdcAddress,
    abi: erc20Abi,
    functionName: "transfer",
    args: [ctx.userAccount.address, minAmount],
  });
  await publicClient.waitForTransactionReceipt({ hash: transferHash });

  return true;
}

export async function ensureAccountHasEth(
  target: `0x${string}`,
  minAmount: bigint,
): Promise<boolean> {
  const current = await publicClient.getBalance({ address: target });
  if (current >= minAmount) return true;

  const adminBal = await publicClient.getBalance({ address: ctx.adminAddress });
  const topUp = minAmount - current;
  if (adminBal <= topUp) {
    console.log(
      `[funding] Skipping ETH top-up: target=${target}, current=${formatUnits(current, 18)} ETH, admin=${formatUnits(adminBal, 18)} ETH`,
    );
    return false;
  }

  const txHash = await walletClient.sendTransaction({
    account: ctx.adminAccount,
    to: target,
    value: topUp,
  });
  await publicClient.waitForTransactionReceipt({ hash: txHash });

  const updated = await publicClient.getBalance({ address: target });
  return updated >= minAmount;
}

export {
  deployments,
  getAbi,
  getBytecode,
  publicClient,
  testClient,
  walletClient,
};
