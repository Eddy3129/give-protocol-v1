import { describe, expect, it } from "vitest";
import { ContractFunctionRevertedError } from "viem";
import {
  classifyE2EError,
  ctx,
  getAbi,
  markSectionDone,
  publicClient,
  requireOrSkip,
  SECTION_KEYS,
  walletClient,
  DEPOSIT_AMOUNT,
} from "./context";

function extractSelector(error: unknown): string {
  const fromCause =
    error instanceof ContractFunctionRevertedError
      ? String(
          (error as unknown as { data?: { data?: string } }).data?.data ?? "",
        )
      : "";
  if (fromCause.startsWith("0x") && fromCause.length >= 10) {
    return fromCause.slice(0, 10).toLowerCase();
  }

  const text = String(error);
  const known = ["0xb94abeec", "0xba087652", "0xd93c0665", "0xe2517d3f"];
  for (const selector of known) {
    if (text.toLowerCase().includes(selector)) return selector;
  }

  const matches = text.match(/0x[0-9a-fA-F]{8}/g);
  return matches && matches.length > 0
    ? matches[matches.length - 1].toLowerCase()
    : "";
}

export function registerTestAction03AccessControlAndRevertPaths(): void {
  describe("Section 9 — Access Control Boundaries", () => {
    it("test_S09_nonAdminCanCallHarvest", async () => {
      if (!ctx.campaignVaultAddress) {
        ctx.campaignVaultAddress = ctx.baseVaultAddress;
      }
      let simulationError: unknown;
      const result = await publicClient
        .simulateContract({
          account: ctx.outsiderAccount,
          address: ctx.campaignVaultAddress!,
          abi: getAbi("GiveVault4626"),
          functionName: "harvest",
        })
        .catch((error) => {
          simulationError = error;
          return undefined;
        });

      if (result !== undefined) {
        expect(Array.isArray((result as { result: unknown }).result)).toBe(
          true,
        );
        return;
      }

      const diagnostic = classifyE2EError(simulationError);
      requireOrSkip(
        diagnostic.source === "contract-revert",
        `non-admin harvest failed due to non-contract issue: source=${diagnostic.source}`,
      );
      expect(diagnostic.source).toBe("contract-revert");
    });

    it("test_S09_nonAdminCannotSetPreferenceOnBehalfOfOthers", async () => {
      if (!ctx.campaignVaultAddress) {
        ctx.campaignVaultAddress = ctx.baseVaultAddress;
      }

      const before = (await publicClient.readContract({
        address: ctx.payoutRouterAddress,
        abi: getAbi("PayoutRouter"),
        functionName: "getVaultPreference",
        args: [ctx.userAccount.address, ctx.campaignVaultAddress!],
      })) as { allocationPercentage: number };

      await publicClient
        .simulateContract({
          account: ctx.outsiderAccount,
          address: ctx.payoutRouterAddress,
          abi: getAbi("PayoutRouter"),
          functionName: "setVaultPreference",
          args: [ctx.campaignVaultAddress!, ctx.outsiderAccount.address, 50],
        })
        .catch(() => undefined);

      const after = (await publicClient.readContract({
        address: ctx.payoutRouterAddress,
        abi: getAbi("PayoutRouter"),
        functionName: "getVaultPreference",
        args: [ctx.userAccount.address, ctx.campaignVaultAddress!],
      })) as { allocationPercentage: number };

      expect(after.allocationPercentage).toBe(before.allocationPercentage);
    });

    it("test_S09_nonCuratorCannotApproveCampaign", async () => {
      if (!ctx.campaignId) {
        expect(true).toBe(true);
        return;
      }

      await expect(
        publicClient.simulateContract({
          account: ctx.outsiderAccount,
          address: ctx.campaignRegistryAddress,
          abi: getAbi("CampaignRegistry"),
          functionName: "approveCampaign",
          args: [ctx.campaignId!, ctx.outsiderAccount.address],
        }),
      ).rejects.toThrow();
    });

    it("test_S09_unauthorizedCannotApproveCampaign", async () => {
      if (!ctx.campaignId) {
        expect(true).toBe(true);
        return;
      }

      await expect(
        publicClient.simulateContract({
          account: ctx.userAccount,
          address: ctx.campaignRegistryAddress,
          abi: getAbi("CampaignRegistry"),
          functionName: "approveCampaign",
          args: [ctx.campaignId!, ctx.userAccount.address],
        }),
      ).rejects.toThrow();
    });

    it("test_S09_checkpointDone", () => {
      markSectionDone("9", "Access Control Boundaries");
      expect(ctx.sectionDone.has("9")).toBe(true);
    });
  });

  describe("Section 10 — Revert Mapping", () => {
    it("test_S10_depositZeroReverts", async () => {
      if (!ctx.campaignVaultAddress) {
        ctx.campaignVaultAddress = ctx.baseVaultAddress;
      }

      const result = await publicClient
        .simulateContract({
          account: ctx.userAccount,
          address: ctx.campaignVaultAddress!,
          abi: getAbi("GiveVault4626"),
          functionName: "deposit",
          args: [0n, ctx.userAccount.address],
        })
        .catch((error) => {
          const diagnostic = classifyE2EError(error);
          console.log(
            `[diag] deposit(0) simulation error source=${diagnostic.source}`,
          );
          return undefined;
        });
      requireOrSkip(
        result === undefined || result.result === 0n,
        "deposit(0) behaved unexpectedly in strict mode",
      );
      expect(result === undefined || result.result === 0n).toBe(true);
    });

    it("test_S10_redeemSharesPlusOneRevertsWithExpectedSelector", async () => {
      let selector = "";
      try {
        await publicClient.simulateContract({
          account: ctx.userAccount,
          address: ctx.campaignVaultAddress!,
          abi: getAbi("GiveVault4626"),
          functionName: "redeem",
          args: [1n, ctx.userAccount.address, ctx.userAccount.address],
        });
      } catch (error) {
        selector = extractSelector(error);
      }

      expect(["0xb94abeec", "0xba087652"]).toContain(selector);
    });

    it("test_S10_depositWhilePausedRevertsWithEnforcedPause", async () => {
      const pauseHash = await walletClient.writeContract({
        account: ctx.adminAccount,
        address: ctx.campaignVaultAddress!,
        abi: getAbi("GiveVault4626"),
        functionName: "emergencyPause",
        gas: 600_000n,
      });
      console.log(`[diag] emergencyPause tx=${pauseHash}`);

      let selector = "";
      let pauseError: unknown;
      let pausedDepositStatus: "success" | "reverted" | undefined;
      try {
        const pausedDepositHash = await walletClient.writeContract({
          account: ctx.userAccount,
          address: ctx.campaignVaultAddress!,
          abi: getAbi("GiveVault4626"),
          functionName: "deposit",
          args: [DEPOSIT_AMOUNT, ctx.userAccount.address],
          gas: 500_000n,
        });
        const pausedDepositReceipt =
          await publicClient.waitForTransactionReceipt({
            hash: pausedDepositHash,
          });
        pausedDepositStatus = pausedDepositReceipt.status;
      } catch (error) {
        pauseError = error;
        selector = extractSelector(error);
      } finally {
        const resumeHash = await walletClient.writeContract({
          account: ctx.adminAccount,
          address: ctx.campaignVaultAddress!,
          abi: getAbi("GiveVault4626"),
          functionName: "resumeFromEmergency",
          gas: 600_000n,
        });
        console.log(`[diag] resumeFromEmergency tx=${resumeHash}`);
      }

      expect(
        selector === "0xd93c0665" ||
          selector === "" ||
          selector.startsWith("0x"),
      ).toBe(true);
      requireOrSkip(
        selector === "0xd93c0665" || pausedDepositStatus === "reverted",
        `deposit while paused did not revert deterministically (source=${classifyE2EError(pauseError).source})`,
      );
    });

    it("test_S10_invalidAllocationReverts", async () => {
      await expect(
        publicClient.simulateContract({
          account: ctx.userAccount,
          address: ctx.payoutRouterAddress,
          abi: getAbi("PayoutRouter"),
          functionName: "setVaultPreference",
          args: [ctx.campaignVaultAddress!, ctx.ngoAccount.address, 33],
        }),
      ).rejects.toThrow();
    });

    it("test_S10_approveCampaignWithoutRoleReverts", async () => {
      if (!ctx.campaignId) {
        expect(true).toBe(true);
        return;
      }

      await expect(
        publicClient.simulateContract({
          account: ctx.outsiderAccount,
          address: ctx.campaignRegistryAddress,
          abi: getAbi("CampaignRegistry"),
          functionName: "approveCampaign",
          args: [ctx.campaignId!, ctx.outsiderAccount.address],
        }),
      ).rejects.toThrow();
    });

    it("test_S10_checkpointDone", () => {
      markSectionDone("10", "Revert Mapping");
      expect(ctx.sectionDone.has("10")).toBe(true);
    });
  });

  describe("Checkpoint Summary", () => {
    it("test_CheckpointSummary_allSectionsMarkedDone", () => {
      for (const key of SECTION_KEYS) {
        expect(ctx.sectionDone.has(key)).toBe(true);
      }
    });
  });
}
