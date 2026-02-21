import { formatUnits, getAddress, parseUnits } from "viem";
import { privateKeyToAccount } from "viem/accounts";
import {
  deployments,
  getAbi,
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
export const STRICT_MODE =
  String(process.env.FRONTEND_E2E_STRICT || "false").toLowerCase() === "true";

const adminAccount = walletClient.account;
if (!adminAccount) {
  throw new Error(
    "walletClient.account is undefined. Configure PRIVATE_KEY, CAST_ACCOUNT, or ACCOUNT_ADDRESS.",
  );
}
const userPrivateKey =
  process.env.USER_PRIVATE_KEY ||
  "0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d";
const outsiderPrivateKey =
  process.env.OUTSIDER_PRIVATE_KEY ||
  "0x5de4111afa1a4b94908f83103a68d8675f2d82fce2f114cc2b03a95ad7faec9a";

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
    (
      process.env.NGO_PRIVATE_KEY ||
      "0x8b3a350cf5c34c9194ca3a545d7f92f492f184f6d89ed8d4fdbd95f8cfb5f4a8"
    ).startsWith("0x")
      ? ((process.env.NGO_PRIVATE_KEY ||
          "0x8b3a350cf5c34c9194ca3a545d7f92f492f184f6d89ed8d4fdbd95f8cfb5f4a8") as `0x${string}`)
      : (`0x${process.env.NGO_PRIVATE_KEY}` as `0x${string}`),
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

  if (STRICT_MODE) {
    throw new Error(`[strict] ${message}`);
  }

  console.log(`[skip] ${message}`);
  return false;
}

export function isZeroBytes32(value?: `0x${string}`): boolean {
  return !value || value.toLowerCase() === `0x${"0".repeat(64)}`;
}

export function getFirstLogArgs<T>(logs: unknown[]): T {
  return (logs[0] as { args: T }).args;
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

export { deployments, getAbi, publicClient, testClient, walletClient };
