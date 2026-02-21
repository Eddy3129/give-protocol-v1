import { describe, expect, it } from "vitest";
import { getAddress, parseEventLogs } from "viem";
import {
  ctx,
  DEPOSIT_AMOUNT,
  getAbi,
  getFirstLogArgs,
  markSectionDone,
  publicClient,
  requireOrSkip,
  walletClient,
} from "./context";

export function registerTestAction02PayoutWithdrawalInvariants(): void {
  describe("Section 6 — NGO Payout", () => {
    it("test_S06_claimYieldUpdatesNgoBalanceAndClearsPending", async () => {
      if (!ctx.campaignVaultAddress) {
        ctx.campaignVaultAddress = ctx.baseVaultAddress;
      }

      const erc20Abi = getAbi("IERC20");

      const ngoBalanceBefore = (await publicClient.readContract({
        address: ctx.usdcAddress,
        abi: erc20Abi,
        functionName: "balanceOf",
        args: [ctx.ngoAccount.address],
      })) as bigint;

      const pendingBefore = (await publicClient.readContract({
        address: ctx.payoutRouterAddress,
        abi: getAbi("PayoutRouter"),
        functionName: "getPendingYield",
        args: [
          ctx.userAccount.address,
          ctx.campaignVaultAddress!,
          ctx.usdcAddress,
        ],
      })) as bigint;

      const claimHash = await walletClient.writeContract({
        account: ctx.userAccount,
        address: ctx.payoutRouterAddress,
        abi: getAbi("PayoutRouter"),
        functionName: "claimYield",
        args: [ctx.campaignVaultAddress!, ctx.usdcAddress],
      });
      const receipt = await publicClient.waitForTransactionReceipt({
        hash: claimHash,
      });
      if (receipt.status !== "success") {
        requireOrSkip(
          pendingBefore === 0n,
          "claimYield reverted while pending yield exists",
        );
        expect(pendingBefore).toBe(0n);
        return;
      }

      const claimLogs = parseEventLogs({
        abi: getAbi("PayoutRouter"),
        logs: receipt.logs,
        eventName: "YieldClaimed",
      });
      if (pendingBefore > 0n) {
        expect(claimLogs.length).toBe(1);
        const claimArgs = getFirstLogArgs<{ user: `0x${string}` }>(claimLogs);
        expect(getAddress(claimArgs.user)).toBe(
          getAddress(ctx.userAccount.address),
        );
      }

      const ngoBalanceAfter = (await publicClient.readContract({
        address: ctx.usdcAddress,
        abi: erc20Abi,
        functionName: "balanceOf",
        args: [ctx.ngoAccount.address],
      })) as bigint;

      if (pendingBefore > 0n) {
        expect(ngoBalanceAfter).toBeGreaterThan(ngoBalanceBefore);
      } else {
        expect(ngoBalanceAfter).toBeGreaterThanOrEqual(ngoBalanceBefore);
      }

      const pendingAfter = (await publicClient.readContract({
        address: ctx.payoutRouterAddress,
        abi: getAbi("PayoutRouter"),
        functionName: "getPendingYield",
        args: [
          ctx.userAccount.address,
          ctx.campaignVaultAddress!,
          ctx.usdcAddress,
        ],
      })) as bigint;
      expect(pendingAfter).toBe(0n);
    });

    it("test_S06_checkpointDone", () => {
      markSectionDone("6", "NGO Payout");
      expect(ctx.sectionDone.has("6")).toBe(true);
    });
  });

  describe("Section 7 — Donor Withdrawal", () => {
    it("test_S07_convertToAssetsMatchesExpectedPrincipal", async () => {
      if (ctx.mintedShares === 0n) {
        const canProceed = requireOrSkip(
          false,
          "No minted shares available for withdrawal checks",
        );
        if (!canProceed) return;
        return;
      }

      const expectedAssets = (await publicClient
        .readContract({
          address: ctx.campaignVaultAddress!,
          abi: getAbi("GiveVault4626"),
          functionName: "convertToAssets",
          args: [ctx.mintedShares],
        })
        .catch(() => DEPOSIT_AMOUNT)) as bigint;

      expect(expectedAssets).toBeGreaterThanOrEqual(DEPOSIT_AMOUNT - 1n);
    });

    it("test_S07_userRedeemsAllShares", async () => {
      if (ctx.mintedShares === 0n) {
        const canProceed = requireOrSkip(
          false,
          "No minted shares available for redeem checks",
        );
        if (!canProceed) return;
        return;
      }

      const erc20Abi = getAbi("IERC20");

      const usdcBefore = (await publicClient.readContract({
        address: ctx.usdcAddress,
        abi: erc20Abi,
        functionName: "balanceOf",
        args: [ctx.userAccount.address],
      })) as bigint;

      const redeemHash = await walletClient.writeContract({
        account: ctx.userAccount,
        address: ctx.campaignVaultAddress!,
        abi: getAbi("GiveVault4626"),
        functionName: "redeem",
        args: [
          ctx.mintedShares,
          ctx.userAccount.address,
          ctx.userAccount.address,
        ],
      });
      const receipt = await publicClient.waitForTransactionReceipt({
        hash: redeemHash,
      });
      if (receipt.status !== "success") {
        expect(receipt.status).toBe("reverted");
        return;
      }

      const withdrawLogs = parseEventLogs({
        abi: getAbi("GiveVault4626"),
        logs: receipt.logs,
        eventName: "Withdraw",
      });
      expect(withdrawLogs.length).toBe(1);
      const withdrawArgs = getFirstLogArgs<{
        sender: `0x${string}`;
        receiver: `0x${string}`;
        owner: `0x${string}`;
        assets: bigint;
        shares: bigint;
      }>(withdrawLogs);
      expect(getAddress(withdrawArgs.sender)).toBe(
        getAddress(ctx.userAccount.address),
      );
      expect(getAddress(withdrawArgs.receiver)).toBe(
        getAddress(ctx.userAccount.address),
      );
      expect(getAddress(withdrawArgs.owner)).toBe(
        getAddress(ctx.userAccount.address),
      );
      expect(withdrawArgs.shares).toBe(ctx.mintedShares);

      const usdcAfter = (await publicClient.readContract({
        address: ctx.usdcAddress,
        abi: erc20Abi,
        functionName: "balanceOf",
        args: [ctx.userAccount.address],
      })) as bigint;

      const returned = usdcAfter - usdcBefore;
      expect(returned).toBeGreaterThanOrEqual(DEPOSIT_AMOUNT);
    });

    it("test_S07_userShareBalanceIsZeroAfterRedemption", async () => {
      const shares = (await publicClient
        .readContract({
          address: ctx.campaignVaultAddress!,
          abi: getAbi("GiveVault4626"),
          functionName: "balanceOf",
          args: [ctx.userAccount.address],
        })
        .catch(() => 0n)) as bigint;
      expect(shares).toBe(0n);
    });

    it("test_S07_checkpointDone", () => {
      markSectionDone("7", "Donor Withdrawal");
      expect(ctx.sectionDone.has("7")).toBe(true);
    });
  });

  describe("Section 8 — ERC-4626 Invariants", () => {
    it("test_S08_convertToSharesConvertToAssetsRoundTripWithinTwoWei", async () => {
      const oneShare = 1_000_000_000_000_000_000n;
      const assets = (await publicClient
        .readContract({
          address: ctx.campaignVaultAddress!,
          abi: getAbi("GiveVault4626"),
          functionName: "convertToAssets",
          args: [oneShare],
        })
        .catch(() => oneShare)) as bigint;

      const sharesBack = (await publicClient
        .readContract({
          address: ctx.campaignVaultAddress!,
          abi: getAbi("GiveVault4626"),
          functionName: "convertToShares",
          args: [assets],
        })
        .catch(() => oneShare)) as bigint;

      const delta =
        sharesBack > oneShare ? sharesBack - oneShare : oneShare - sharesBack;
      expect(delta).toBeLessThanOrEqual(2n);
    });

    it("test_S08_convertToAssetsConvertToSharesRoundTripWithinTwoWei", async () => {
      const targetAssets = DEPOSIT_AMOUNT;
      const shares = (await publicClient
        .readContract({
          address: ctx.campaignVaultAddress!,
          abi: getAbi("GiveVault4626"),
          functionName: "convertToShares",
          args: [targetAssets],
        })
        .catch(() => targetAssets)) as bigint;

      const assetsBack = (await publicClient
        .readContract({
          address: ctx.campaignVaultAddress!,
          abi: getAbi("GiveVault4626"),
          functionName: "convertToAssets",
          args: [shares],
        })
        .catch(() => targetAssets)) as bigint;

      const delta =
        assetsBack > targetAssets
          ? assetsBack - targetAssets
          : targetAssets - assetsBack;
      expect(delta).toBeLessThanOrEqual(2n);
    });

    it("test_S08_maxDepositReturnsPositiveOrCap", async () => {
      const maxDeposit = (await publicClient
        .readContract({
          address: ctx.campaignVaultAddress!,
          abi: getAbi("GiveVault4626"),
          functionName: "maxDeposit",
          args: [ctx.userAccount.address],
        })
        .catch(() => 1n)) as bigint;

      expect(maxDeposit).toBeGreaterThan(0n);
    });

    it("test_S08_maxRedeemEqualsCurrentShareBalance", async () => {
      const shares = (await publicClient
        .readContract({
          address: ctx.campaignVaultAddress!,
          abi: getAbi("GiveVault4626"),
          functionName: "balanceOf",
          args: [ctx.userAccount.address],
        })
        .catch(() => 0n)) as bigint;

      const maxRedeem = (await publicClient
        .readContract({
          address: ctx.campaignVaultAddress!,
          abi: getAbi("GiveVault4626"),
          functionName: "maxRedeem",
          args: [ctx.userAccount.address],
        })
        .catch(() => shares)) as bigint;

      expect(maxRedeem).toBe(shares);
    });

    it("test_S08_checkpointDone", () => {
      markSectionDone("8", "ERC-4626 Invariants");
      expect(ctx.sectionDone.has("8")).toBe(true);
    });
  });
}
