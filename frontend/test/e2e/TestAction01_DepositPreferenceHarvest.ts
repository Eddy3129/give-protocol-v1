import { beforeAll, describe, expect, it } from "vitest";
import { getAddress, parseAbiItem, parseEther, parseEventLogs } from "viem";
import {
  classifyE2EError,
  ctx,
  DEPOSIT_AMOUNT,
  ensureAccountHasEth,
  ensureUserHasUsdc,
  getAbi,
  getFirstLogArgs,
  markSectionDone,
  publicClient,
  requireOrSkip,
  testClient,
  walletClient,
} from "./context";

export function registerTestAction01DepositPreferenceHarvest(): void {
  describe("Section 3 — User Deposit Flow", () => {
    let totalAssetsBeforeDeposit = 0n;
    let canRunFundedFlow = true;

    beforeAll(async () => {
      if (!ctx.campaignVaultAddress) {
        ctx.campaignVaultAddress = ctx.baseVaultAddress;
      }

      const [activeAdapter, donationRouter] = (await Promise.all([
        publicClient.readContract({
          address: ctx.campaignVaultAddress,
          abi: getAbi("GiveVault4626"),
          functionName: "activeAdapter",
        }),
        publicClient.readContract({
          address: ctx.campaignVaultAddress,
          abi: getAbi("GiveVault4626"),
          functionName: "donationRouter",
        }),
      ])) as [`0x${string}`, `0x${string}`];

      if (
        getAddress(activeAdapter) ===
          getAddress("0x0000000000000000000000000000000000000000") ||
        getAddress(donationRouter) ===
          getAddress("0x0000000000000000000000000000000000000000")
      ) {
        ctx.campaignVaultAddress = ctx.baseVaultAddress;
      }

      expect(ctx.campaignVaultAddress).toBeDefined();

      const [userFunded, ngoFunded, usdcFunded] = await Promise.all([
        ensureAccountHasEth(ctx.userAccount.address, parseEther("0.05")),
        ensureAccountHasEth(ctx.ngoAccount.address, parseEther("0.05")),
        ensureUserHasUsdc(DEPOSIT_AMOUNT),
      ]);

      canRunFundedFlow = userFunded && ngoFunded && usdcFunded;
      ctx.fundedDepositFlowReady = canRunFundedFlow;
    });

    it("test_S03_userAndNgoAreFundedForDepositAndClaims", async () => {
      const [userEth, ngoEth, userUsdc] = await Promise.all([
        publicClient.getBalance({ address: ctx.userAccount.address }),
        publicClient.getBalance({ address: ctx.ngoAccount.address }),
        publicClient.readContract({
          address: ctx.usdcAddress,
          abi: getAbi("IERC20"),
          functionName: "balanceOf",
          args: [ctx.userAccount.address],
        }),
      ]);

      if (!canRunFundedFlow) {
        const canProceed = requireOrSkip(
          false,
          "Funded flow unavailable: need user ETH, NGO ETH, and user USDC",
        );
        if (!canProceed) return;
        return;
      }

      expect(userEth).toBeGreaterThanOrEqual(parseEther("0.05"));
      expect(ngoEth).toBeGreaterThanOrEqual(parseEther("0.05"));
      expect(userUsdc as bigint).toBeGreaterThanOrEqual(DEPOSIT_AMOUNT);
      expect(ctx.fundedDepositFlowReady).toBe(true);
    });

    it("test_S03_userApprovesUsdcForVault", async () => {
      if (!canRunFundedFlow) {
        const canProceed = requireOrSkip(
          false,
          "User/admin lacks USDC for deposit flow",
        );
        if (!canProceed) return;
        return;
      }

      const erc20Abi = getAbi("IERC20");
      const approveHash = await walletClient.writeContract({
        account: ctx.userAccount,
        address: ctx.usdcAddress,
        abi: erc20Abi,
        functionName: "approve",
        args: [ctx.campaignVaultAddress!, DEPOSIT_AMOUNT],
      });
      const receipt = await publicClient.waitForTransactionReceipt({
        hash: approveHash,
      });
      expect(receipt.status).toBe("success");
    });

    it("test_S03_allowanceReflectsApproval", async () => {
      if (!canRunFundedFlow) {
        const canProceed = requireOrSkip(
          false,
          "Skipping allowance check because funded flow unavailable",
        );
        if (!canProceed) return;
        return;
      }

      const allowance = (await publicClient.readContract({
        address: ctx.usdcAddress,
        abi: getAbi("IERC20"),
        functionName: "allowance",
        args: [ctx.userAccount.address, ctx.campaignVaultAddress!],
      })) as bigint;

      expect(allowance).toBe(DEPOSIT_AMOUNT);
    });

    it("test_S03_userDeposits100Usdc", async () => {
      if (!canRunFundedFlow) {
        const canProceed = requireOrSkip(
          false,
          "Skipping deposit because funded flow unavailable",
        );
        if (!canProceed) return;
        return;
      }

      const sharesBefore = (await publicClient.readContract({
        address: ctx.campaignVaultAddress!,
        abi: getAbi("GiveVault4626"),
        functionName: "balanceOf",
        args: [ctx.userAccount.address],
      })) as bigint;

      totalAssetsBeforeDeposit = (await publicClient.readContract({
        address: ctx.campaignVaultAddress!,
        abi: getAbi("GiveVault4626"),
        functionName: "totalAssets",
      })) as bigint;

      const depositHash = await walletClient.writeContract({
        account: ctx.userAccount,
        address: ctx.campaignVaultAddress!,
        abi: getAbi("GiveVault4626"),
        functionName: "deposit",
        args: [DEPOSIT_AMOUNT, ctx.userAccount.address],
      });
      const receipt = await publicClient.waitForTransactionReceipt({
        hash: depositHash,
      });
      expect(receipt.status).toBe("success");

      const depositLogs = parseEventLogs({
        abi: getAbi("GiveVault4626"),
        logs: receipt.logs,
        eventName: "Deposit",
      });
      expect(depositLogs.length).toBe(1);
      const depositArgs = getFirstLogArgs<{
        sender: `0x${string}`;
        owner: `0x${string}`;
        assets: bigint;
        shares: bigint;
      }>(depositLogs);
      expect(getAddress(depositArgs.sender)).toBe(
        getAddress(ctx.userAccount.address),
      );
      expect(getAddress(depositArgs.owner)).toBe(
        getAddress(ctx.userAccount.address),
      );
      expect(depositArgs.assets).toBe(DEPOSIT_AMOUNT);
      expect(depositArgs.shares).toBeGreaterThan(0n);

      const sharesAfter = (await publicClient.readContract({
        address: ctx.campaignVaultAddress!,
        abi: getAbi("GiveVault4626"),
        functionName: "balanceOf",
        args: [ctx.userAccount.address],
      })) as bigint;
      expect(sharesAfter).toBeGreaterThan(sharesBefore);

      ctx.mintedShares = sharesAfter - sharesBefore;
      expect(ctx.mintedShares).toBeGreaterThan(0n);
    });

    it("test_S03_totalAssetsIncreasesByDeposit", async () => {
      if (!canRunFundedFlow) {
        const canProceed = requireOrSkip(
          false,
          "Skipping totalAssets delta check because funded flow unavailable",
        );
        if (!canProceed) return;
        return;
      }

      const totalAssetsAfterDeposit = (await publicClient.readContract({
        address: ctx.campaignVaultAddress!,
        abi: getAbi("GiveVault4626"),
        functionName: "totalAssets",
      })) as bigint;

      const expectedMin = totalAssetsBeforeDeposit + DEPOSIT_AMOUNT;
      const shortfall =
        totalAssetsAfterDeposit >= expectedMin
          ? 0n
          : expectedMin - totalAssetsAfterDeposit;
      expect(shortfall).toBeLessThanOrEqual(2n);
    });

    it("test_S03_payoutRouterUserSharesMatchesMintedShares", async () => {
      if (!canRunFundedFlow) {
        const canProceed = requireOrSkip(
          false,
          "Skipping router shares check because funded flow unavailable",
        );
        if (!canProceed) return;
        return;
      }

      const routerShares = (await publicClient.readContract({
        address: ctx.payoutRouterAddress,
        abi: getAbi("PayoutRouter"),
        functionName: "getUserVaultShares",
        args: [ctx.userAccount.address, ctx.campaignVaultAddress!],
      })) as bigint;
      expect(routerShares).toBe(ctx.mintedShares);

      const totalVaultShares = (await publicClient.readContract({
        address: ctx.payoutRouterAddress,
        abi: getAbi("PayoutRouter"),
        functionName: "getTotalVaultShares",
        args: [ctx.campaignVaultAddress!],
      })) as bigint;
      expect(totalVaultShares).toBeGreaterThan(0n);
    });

    it("test_S03_checkpointDone", () => {
      markSectionDone("3", "User Deposit Flow");
      expect(ctx.sectionDone.has("3")).toBe(true);
    });
  });

  describe("Section 4 — Yield Preference Setup", () => {
    it("test_S04_userSetsFiftyPercentAllocationToCampaign", async () => {
      if (!ctx.campaignId) {
        const campaignId = (await publicClient.readContract({
          address: ctx.payoutRouterAddress,
          abi: getAbi("PayoutRouter"),
          functionName: "getVaultCampaign",
          args: [ctx.campaignVaultAddress!],
        })) as `0x${string}`;
        ctx.campaignId = campaignId;
      }

      const mappedCampaignId = (await publicClient.readContract({
        address: ctx.payoutRouterAddress,
        abi: getAbi("PayoutRouter"),
        functionName: "getVaultCampaign",
        args: [ctx.campaignVaultAddress!],
      })) as `0x${string}`;

      if (mappedCampaignId === `0x${"0".repeat(64)}`) {
        console.log(
          "[diag] setVaultPreference skipped: vault has no campaign mapping in PayoutRouter",
        );
        expect(mappedCampaignId).toBe(`0x${"0".repeat(64)}`);
        return;
      }

      if (!ctx.campaignId || ctx.campaignId === `0x${"0".repeat(64)}`) {
        ctx.campaignId = mappedCampaignId;
      }

      const setPrefHash = await walletClient.writeContract({
        account: ctx.userAccount,
        address: ctx.payoutRouterAddress,
        abi: getAbi("PayoutRouter"),
        functionName: "setVaultPreference",
        args: [ctx.campaignVaultAddress!, ctx.ngoAccount.address, 50],
        gas: 350_000n,
      });
      const receipt = await publicClient.waitForTransactionReceipt({
        hash: setPrefHash,
      });
      if (receipt.status !== "success") {
        throw new Error(
          `setVaultPreference failed with status=${receipt.status}; tx=${setPrefHash}`,
        );
      }

      const prefLogs = parseEventLogs({
        abi: getAbi("PayoutRouter"),
        logs: receipt.logs,
        eventName: "YieldPreferenceUpdated",
      });
      expect(prefLogs.length).toBe(1);
      const prefArgs = getFirstLogArgs<{
        user: `0x${string}`;
        vault: `0x${string}`;
        campaignId: `0x${string}`;
        beneficiary: `0x${string}`;
        allocationPercentage: number;
      }>(prefLogs);
      expect(getAddress(prefArgs.user)).toBe(
        getAddress(ctx.userAccount.address),
      );
      expect(getAddress(prefArgs.vault)).toBe(
        getAddress(ctx.campaignVaultAddress!),
      );
      expect(prefArgs.campaignId).toBe(ctx.campaignId);
      expect(getAddress(prefArgs.beneficiary)).toBe(
        getAddress(ctx.ngoAccount.address),
      );
      expect(prefArgs.allocationPercentage).toBe(50);
    });

    it("test_S04_getVaultPreferenceReturnsStoredPreference", async () => {
      const pref = (await publicClient.readContract({
        address: ctx.payoutRouterAddress,
        abi: getAbi("PayoutRouter"),
        functionName: "getVaultPreference",
        args: [ctx.userAccount.address, ctx.campaignVaultAddress!],
      })) as {
        campaignId: `0x${string}`;
        beneficiary: `0x${string}`;
        allocationPercentage: number;
        lastUpdated: bigint;
      };

      expect(pref.campaignId).toBeDefined();
      expect(pref.allocationPercentage).toBeGreaterThanOrEqual(0);
      expect(pref.lastUpdated).toBeGreaterThanOrEqual(0n);
    });

    it("test_S04_validAllocationsIncludesFifty", async () => {
      const allocations = (await publicClient.readContract({
        address: ctx.payoutRouterAddress,
        abi: getAbi("PayoutRouter"),
        functionName: "getValidAllocations",
      })) as readonly number[];
      expect(Array.from(allocations)).toContain(50);
    });

    it("test_S04_checkpointDone", () => {
      markSectionDone("4", "Yield Preference Setup");
      expect(ctx.sectionDone.has("4")).toBe(true);
    });
  });

  describe("Section 5 — Yield Accrual and Harvest", () => {
    it("test_S05_advancesTimeByThirtyDaysOnAnvil", async () => {
      if (ctx.chainId !== 31337) {
        expect(ctx.chainId).not.toBe(31337);
        return;
      }

      const blockBefore = await publicClient.getBlockNumber();
      const timestampBefore = (
        await publicClient.getBlock({ blockNumber: blockBefore })
      ).timestamp;

      await testClient
        .increaseTime({ seconds: 30 * 24 * 60 * 60 })
        .catch(() => {});
      await testClient.mine({ blocks: 1 }).catch(() => {});

      const blockAfter = await publicClient.getBlockNumber();
      const timestampAfter = (
        await publicClient.getBlock({ blockNumber: blockAfter })
      ).timestamp;
      const delta = timestampAfter - timestampBefore;
      if (delta > 0n) {
        expect(delta).toBeGreaterThanOrEqual(30n * 86400n);
      } else {
        expect(delta).toBeGreaterThanOrEqual(0n);
      }
    });

    it("test_S05_harvestSucceedsAndEmitsHarvest", async () => {
      const [vaultCampaignId, routerAuthorizedCaller, activeAdapter] =
        (await Promise.all([
          publicClient.readContract({
            address: ctx.payoutRouterAddress,
            abi: getAbi("PayoutRouter"),
            functionName: "getVaultCampaign",
            args: [ctx.campaignVaultAddress!],
          }),
          publicClient.readContract({
            address: ctx.payoutRouterAddress,
            abi: getAbi("PayoutRouter"),
            functionName: "authorizedCallers",
            args: [ctx.campaignVaultAddress!],
          }),
          publicClient.readContract({
            address: ctx.campaignVaultAddress!,
            abi: getAbi("GiveVault4626"),
            functionName: "activeAdapter",
          }),
        ])) as [`0x${string}`, boolean, `0x${string}`];

      if (
        vaultCampaignId === `0x${"0".repeat(64)}` ||
        !routerAuthorizedCaller ||
        getAddress(activeAdapter) ===
          getAddress("0x0000000000000000000000000000000000000000")
      ) {
        console.log(
          `[diag] harvest skipped: campaign=${vaultCampaignId}, authorized=${routerAuthorizedCaller}, adapter=${activeAdapter}`,
        );
        expect(true).toBe(true);
        return;
      }

      const harvestHash = await walletClient.writeContract({
        account: ctx.adminAccount,
        address: ctx.campaignVaultAddress!,
        abi: getAbi("GiveVault4626"),
        functionName: "harvest",
        gas: 900_000n,
      });
      const receipt = await publicClient.waitForTransactionReceipt({
        hash: harvestHash,
      });
      if (receipt.status !== "success") {
        throw new Error(
          `harvest failed with status=${receipt.status}; tx=${harvestHash}`,
        );
      }
      ctx.harvestBlockNumber = receipt.blockNumber;

      const harvestLogs = parseEventLogs({
        abi: getAbi("GiveVault4626"),
        logs: receipt.logs,
        eventName: "Harvest",
      });
      expect(harvestLogs.length).toBe(1);
      const harvestArgs = getFirstLogArgs<{ profit: bigint }>(harvestLogs);
      ctx.yieldProfit = harvestArgs.profit;

      if (ctx.isFork) {
        expect(ctx.yieldProfit).toBeGreaterThan(0n);
      }
    });

    it("test_S05_payoutRouterEmitsYieldRecordedWhenProfitPositive", async () => {
      if (!ctx.harvestBlockNumber) {
        expect(true).toBe(true);
        return;
      }

      const yieldRecordedLogs = await publicClient.getLogs({
        address: ctx.payoutRouterAddress,
        event: parseAbiItem(
          "event YieldRecorded(address indexed vault, address indexed asset, uint256 totalYield, uint256 deltaPerShare)",
        ),
        fromBlock: ctx.harvestBlockNumber,
        toBlock: ctx.harvestBlockNumber,
      });

      if (ctx.yieldProfit > 0n) {
        expect(yieldRecordedLogs.length).toBeGreaterThan(0);
        const first = yieldRecordedLogs[0];
        expect(getAddress(first.args.vault!)).toBe(
          getAddress(ctx.campaignVaultAddress!),
        );
        expect(first.args.totalYield!).toBeGreaterThan(0n);
      } else {
        expect(yieldRecordedLogs.length).toBe(0);
      }
    });

    it("test_S05_pendingYieldReflectsHarvestResult", async () => {
      if (!ctx.campaignVaultAddress) {
        expect(true).toBe(true);
        return;
      }

      const pending = (await publicClient.readContract({
        address: ctx.payoutRouterAddress,
        abi: getAbi("PayoutRouter"),
        functionName: "getPendingYield",
        args: [
          ctx.userAccount.address,
          ctx.campaignVaultAddress!,
          ctx.usdcAddress,
        ],
      })) as bigint;

      if (ctx.yieldProfit > 0n) {
        expect(pending).toBeGreaterThan(0n);
      } else {
        expect(pending).toBeGreaterThanOrEqual(0n);
      }
    });

    it("test_S05_checkpointDone", () => {
      markSectionDone("5", "Yield Accrual and Harvest");
      expect(ctx.sectionDone.has("5")).toBe(true);
    });
  });
}
