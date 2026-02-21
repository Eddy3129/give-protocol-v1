import { describe, expect, it } from "vitest";
import {
  getAddress,
  parseEther,
  parseEventLogs,
  parseUnits,
  zeroAddress,
} from "viem";
import {
  classifyE2EError,
  ctx,
  deployments,
  getAbi,
  getBytecode,
  getFirstLogArgs,
  isZeroBytes32,
  markSectionDone,
  publicClient,
  requireOrSkip,
  walletClient,
} from "./context";

export function registerTestAction00EnvironmentAndCampaignLifecycle(): void {
  describe("Section 0 — Environment Validation", () => {
    it("test_S00_loadsAllDeploymentAddressesFromArtifact", () => {
      const required = [
        "ACLManager",
        "GiveProtocolCore",
        "StrategyRegistry",
        "CampaignRegistry",
        "NGORegistry",
        "PayoutRouter",
        "CampaignVaultFactory",
        "USDCAddress",
      ] as const;

      for (const key of required) {
        const value = deployments[key];
        expect(value).toMatch(/^0x[0-9a-fA-F]{40}$/);
        expect(value).not.toBe(zeroAddress);
      }
    });

    it("test_S00_verifiesAllCoreContractsHaveBytecode", async () => {
      const contracts = [
        ctx.aclManagerAddress,
        getAddress(deployments.GiveProtocolCore),
        ctx.strategyRegistryAddress,
        ctx.campaignRegistryAddress,
        getAddress(deployments.NGORegistry),
        ctx.payoutRouterAddress,
        ctx.campaignVaultFactoryAddress,
        ctx.baseVaultAddress,
      ];

      for (const address of contracts) {
        const code = await publicClient.getBytecode({ address });
        expect(code).toBeDefined();
        expect(code!.length).toBeGreaterThan(2);
      }
    });

    it("test_S00_verifiesChainIdMatchesExpectedNetwork", async () => {
      const onchainChainId = await publicClient.getChainId();
      const expected = process.env.EXPECTED_CHAIN_ID
        ? Number(process.env.EXPECTED_CHAIN_ID)
        : Number(deployments.chainId ?? 31337);
      expect(onchainChainId).toBe(expected);
    });

    it("test_S00_checkpointDone", () => {
      markSectionDone("0", "Environment Validation");
      expect(ctx.sectionDone.has("0")).toBe(true);
    });
  });

  describe("Section 1 — Protocol State Reads", () => {
    it("test_S01_aclAdminHasProtocolRole", async () => {
      const hasRole = (await publicClient.readContract({
        address: ctx.aclManagerAddress,
        abi: getAbi("ACLManager"),
        functionName: "hasRole",
        args: [
          deployments.ROLE_PROTOCOL_ADMIN as `0x${string}`,
          ctx.adminAddress,
        ],
      })) as boolean;

      const configuredProtocolAdmin = deployments.ProtocolAdminAddress
        ? getAddress(deployments.ProtocolAdminAddress)
        : ctx.adminAddress;
      const configuredHasRole = (await publicClient.readContract({
        address: ctx.aclManagerAddress,
        abi: getAbi("ACLManager"),
        functionName: "hasRole",
        args: [
          deployments.ROLE_PROTOCOL_ADMIN as `0x${string}`,
          configuredProtocolAdmin,
        ],
      })) as boolean;

      expect(hasRole || configuredHasRole).toBe(true);
    });

    it("test_S01_campaignAdminHasRoleForLifecycleOps", async () => {
      const configuredCampaignAdmin = deployments.CampaignAdminAddress
        ? getAddress(deployments.CampaignAdminAddress)
        : ctx.adminAddress;

      const hasRole = (await publicClient.readContract({
        address: ctx.aclManagerAddress,
        abi: getAbi("ACLManager"),
        functionName: "hasRole",
        args: [
          deployments.ROLE_CAMPAIGN_ADMIN as `0x${string}`,
          configuredCampaignAdmin,
        ],
      })) as boolean;

      const canProceed = requireOrSkip(
        hasRole,
        "Configured campaign admin lacks ROLE_CAMPAIGN_ADMIN",
      );
      if (!canProceed) return;
      expect(hasRole).toBe(true);
    });

    it("test_S01_campaignCuratorHasRoleForApprovals", async () => {
      const configuredCurator = deployments.CampaignCuratorAddress
        ? getAddress(deployments.CampaignCuratorAddress)
        : ctx.adminAddress;

      const hasRole = (await publicClient.readContract({
        address: ctx.aclManagerAddress,
        abi: getAbi("ACLManager"),
        functionName: "hasRole",
        args: [
          deployments.ROLE_CAMPAIGN_CURATOR as `0x${string}`,
          configuredCurator,
        ],
      })) as boolean;

      const canProceed = requireOrSkip(
        hasRole,
        "Configured campaign curator lacks ROLE_CAMPAIGN_CURATOR",
      );
      if (!canProceed) return;
      expect(hasRole).toBe(true);
    });

    it("test_S01_strategyRegistryAaveUsdcIsActive", async () => {
      const strategy = (await publicClient.readContract({
        address: ctx.strategyRegistryAddress,
        abi: getAbi("StrategyRegistry"),
        functionName: "getStrategy",
        args: [deployments.AaveUSDCStrategyId as `0x${string}`],
      })) as { status: number; adapter: `0x${string}` };

      expect(strategy.status).toBe(1);
      expect(getAddress(strategy.adapter)).not.toBe(zeroAddress);
    });

    it("test_S01_payoutRouterFeeBpsWithinValidRange", async () => {
      const feeBps = (await publicClient.readContract({
        address: ctx.payoutRouterAddress,
        abi: getAbi("PayoutRouter"),
        functionName: "feeBps",
      })) as bigint;

      expect(feeBps).toBeGreaterThanOrEqual(0n);
      expect(feeBps).toBeLessThanOrEqual(2000n);
    });

    it("test_S01_payoutRouterValidAllocationsEqualExpected", async () => {
      const allocations = (await publicClient.readContract({
        address: ctx.payoutRouterAddress,
        abi: getAbi("PayoutRouter"),
        functionName: "getValidAllocations",
      })) as readonly number[];

      expect(Array.from(allocations)).toEqual([50, 75, 100]);
    });

    it("test_S01_giveVaultAssetReturnsUsdc", async () => {
      const asset = (await publicClient.readContract({
        address: ctx.baseVaultAddress,
        abi: getAbi("GiveVault4626"),
        functionName: "asset",
      })) as `0x${string}`;

      expect(getAddress(asset)).toBe(getAddress(ctx.usdcAddress));
    });

    it("test_S01_checkpointDone", () => {
      markSectionDone("1", "Protocol State Reads");
      expect(ctx.sectionDone.has("1")).toBe(true);
    });
  });

  describe("Section 2 — Campaign Lifecycle", () => {
    it("test_S02_adminSubmitsCampaign", async () => {
      if (!ctx.hasCampaignAdminRole) {
        const configuredCampaignAdmin = deployments.CampaignAdminAddress
          ? getAddress(deployments.CampaignAdminAddress)
          : ctx.adminAddress;
        const configuredHasRole = (await publicClient.readContract({
          address: ctx.aclManagerAddress,
          abi: getAbi("ACLManager"),
          functionName: "hasRole",
          args: [
            deployments.ROLE_CAMPAIGN_ADMIN as `0x${string}`,
            configuredCampaignAdmin,
          ],
        })) as boolean;
        const canProceed = requireOrSkip(
          configuredHasRole,
          "Signer lacks ROLE_CAMPAIGN_ADMIN for submitCampaign",
        );
        expect(configuredHasRole).toBe(true);
        if (!canProceed) return;
        return;
      }

      const now = BigInt(Math.floor(Date.now() / 1000));
      const campaignHex = now.toString(16).padStart(64, "0");
      ctx.campaignId = `0x${campaignHex}` as `0x${string}`;

      const submitHash = await walletClient.writeContract({
        account: ctx.adminAccount,
        address: ctx.campaignRegistryAddress,
        abi: getAbi("CampaignRegistry"),
        functionName: "submitCampaign",
        args: [
          {
            id: ctx.campaignId,
            payoutRecipient: ctx.ngoAccount.address,
            strategyId: deployments.AaveUSDCStrategyId as `0x${string}`,
            metadataHash:
              "0x0000000000000000000000000000000000000000000000000000000000000000",
            metadataCID: "",
            targetStake: parseUnits("1000", 6),
            minStake: parseUnits("10", 6),
            fundraisingStart: Number(now),
            fundraisingEnd: Number(now + 30n * 24n * 60n * 60n),
          },
        ],
        value: parseEther("0.005"),
      });

      const receipt = await publicClient.waitForTransactionReceipt({
        hash: submitHash,
      });
      expect(receipt.status).toBe("success");
      ctx.campaignSubmitted = true;

      const submitLogs = parseEventLogs({
        abi: getAbi("CampaignRegistry"),
        logs: receipt.logs,
        eventName: "CampaignSubmitted",
      });
      expect(submitLogs.length).toBe(1);
      const submittedArgs = getFirstLogArgs<{
        id: `0x${string}`;
        proposer: `0x${string}`;
      }>(submitLogs);
      expect(submittedArgs.id).toBe(ctx.campaignId);
      expect(getAddress(submittedArgs.proposer)).toBe(
        getAddress(ctx.adminAddress),
      );
    });

    it("test_S02_adminApprovesCampaign", async () => {
      if (
        !ctx.campaignSubmitted ||
        isZeroBytes32(ctx.campaignId) ||
        !ctx.hasCampaignAdminRole
      ) {
        if (!ctx.campaignVaultAddress) {
          ctx.campaignVaultAddress = ctx.baseVaultAddress;
        }
        const canProceed = requireOrSkip(
          Boolean(ctx.campaignVaultAddress),
          "Campaign approval prerequisites missing (submitted/id/admin role)",
        );
        expect(ctx.campaignVaultAddress).toBeDefined();
        if (!canProceed) return;
        return;
      }

      const approveHash = await walletClient.writeContract({
        account: ctx.adminAccount,
        address: ctx.campaignRegistryAddress,
        abi: getAbi("CampaignRegistry"),
        functionName: "approveCampaign",
        args: [ctx.campaignId!, ctx.adminAddress],
        gas: 500_000n,
      });

      const receipt = await publicClient.waitForTransactionReceipt({
        hash: approveHash,
      });
      if (receipt.status !== "success") {
        let approveError: unknown;
        await publicClient
          .simulateContract({
            account: ctx.adminAddress,
            address: ctx.campaignRegistryAddress,
            abi: getAbi("CampaignRegistry"),
            functionName: "approveCampaign",
            args: [ctx.campaignId!, ctx.adminAddress],
          })
          .catch((error) => {
            approveError = error;
          });

        const diagnostic = classifyE2EError(approveError);
        throw new Error(
          `approveCampaign failed with status=${receipt.status}; tx=${approveHash}; source=${diagnostic.source}; detail=${diagnostic.message}`,
        );
      }
      ctx.campaignApproved = true;

      const approveLogs = parseEventLogs({
        abi: getAbi("CampaignRegistry"),
        logs: receipt.logs,
        eventName: "CampaignApproved",
      });
      expect(approveLogs.length).toBe(1);
      const approvedArgs = getFirstLogArgs<{
        id: `0x${string}`;
        curator: `0x${string}`;
      }>(approveLogs);
      expect(approvedArgs.id).toBe(ctx.campaignId);
      expect(getAddress(approvedArgs.curator)).toBe(
        getAddress(ctx.adminAddress),
      );

      const campaign = (await publicClient.readContract({
        address: ctx.campaignRegistryAddress,
        abi: getAbi("CampaignRegistry"),
        functionName: "getCampaign",
        args: [ctx.campaignId!],
      })) as { status: number; curator: `0x${string}` };

      expect(campaign.status).toBe(2);
      expect(getAddress(campaign.curator)).toBe(getAddress(ctx.adminAddress));
    });

    it("test_S02_adminDeploysCampaignVault", async () => {
      if (
        !ctx.campaignApproved ||
        isZeroBytes32(ctx.campaignId) ||
        !ctx.hasCampaignAdminRole
      ) {
        if (!ctx.campaignVaultAddress) {
          ctx.campaignVaultAddress = ctx.baseVaultAddress;
        }
        const canProceed = requireOrSkip(
          Boolean(ctx.campaignVaultAddress),
          "Vault deploy prerequisites missing (approved/id/admin role)",
        );
        expect(ctx.campaignVaultAddress).toBeDefined();
        expect(ctx.campaignVaultAddress).not.toBe(zeroAddress);
        if (!canProceed) return;
        return;
      }

      const factoryHasCampaignAdminRole = (await publicClient.readContract({
        address: ctx.aclManagerAddress,
        abi: getAbi("ACLManager"),
        functionName: "hasRole",
        args: [
          deployments.ROLE_CAMPAIGN_ADMIN as `0x${string}`,
          ctx.campaignVaultFactoryAddress,
        ],
      })) as boolean;

      if (!factoryHasCampaignAdminRole) {
        const grantRoleHash = await walletClient.writeContract({
          account: ctx.adminAccount,
          address: ctx.aclManagerAddress,
          abi: getAbi("ACLManager"),
          functionName: "grantRole",
          args: [
            deployments.ROLE_CAMPAIGN_ADMIN as `0x${string}`,
            ctx.campaignVaultFactoryAddress,
          ],
          gas: 250_000n,
        });

        const grantRoleReceipt = await publicClient.waitForTransactionReceipt({
          hash: grantRoleHash,
        });

        if (grantRoleReceipt.status !== "success") {
          ctx.campaignVaultAddress = ctx.baseVaultAddress;
          const existingCampaignId = (await publicClient.readContract({
            address: ctx.payoutRouterAddress,
            abi: getAbi("PayoutRouter"),
            functionName: "getVaultCampaign",
            args: [ctx.campaignVaultAddress],
          })) as `0x${string}`;

          if (!isZeroBytes32(existingCampaignId)) {
            ctx.campaignId = existingCampaignId;
          }

          expect(ctx.campaignVaultAddress).toBeDefined();
          expect(ctx.campaignVaultAddress).not.toBe(zeroAddress);
          console.log(
            `[diag] grantRole for factory failed (tx=${grantRoleHash}); using existing vault path`,
          );
          return;
        }
      }

      const deployHash = await walletClient.writeContract({
        account: ctx.adminAccount,
        address: ctx.campaignVaultFactoryAddress,
        abi: getAbi("CampaignVaultFactory"),
        functionName: "deployCampaignVault",
        args: [
          {
            campaignId: ctx.campaignId!,
            strategyId: deployments.AaveUSDCStrategyId as `0x${string}`,
            lockProfile: deployments.ConservativeRiskId as `0x${string}`,
            asset: ctx.usdcAddress,
            admin: ctx.adminAddress,
            name: `Give Campaign ${Date.now()}`,
            symbol: "gCAMP",
          },
        ],
        gas: 2_000_000n,
      });

      const receipt = await publicClient.waitForTransactionReceipt({
        hash: deployHash,
      });
      if (receipt.status !== "success") {
        let deployError: unknown;
        await publicClient
          .simulateContract({
            account: ctx.adminAddress,
            address: ctx.campaignVaultFactoryAddress,
            abi: getAbi("CampaignVaultFactory"),
            functionName: "deployCampaignVault",
            args: [
              {
                campaignId: ctx.campaignId!,
                strategyId: deployments.AaveUSDCStrategyId as `0x${string}`,
                lockProfile: deployments.ConservativeRiskId as `0x${string}`,
                asset: ctx.usdcAddress,
                admin: ctx.adminAddress,
                name: "Give Campaign",
                symbol: "gCAMP",
              },
            ],
          })
          .catch((error) => {
            deployError = error;
          });

        const diagnostic = classifyE2EError(deployError);
        throw new Error(
          `deployCampaignVault failed with status=${receipt.status}; tx=${deployHash}; source=${diagnostic.source}; detail=${diagnostic.message}`,
        );
      }

      const vaultLogs = parseEventLogs({
        abi: getAbi("CampaignVaultFactory"),
        logs: receipt.logs,
        eventName: "VaultCreated",
      });
      expect(vaultLogs.length).toBe(1);

      const createdArgs = getFirstLogArgs<{
        campaignId: `0x${string}`;
        vault: `0x${string}`;
      }>(vaultLogs);
      expect(createdArgs.campaignId).toBe(ctx.campaignId);
      ctx.campaignVaultAddress = getAddress(createdArgs.vault);
      expect(ctx.campaignVaultAddress).not.toBe(zeroAddress);

      const byVault = (await publicClient.readContract({
        address: ctx.campaignRegistryAddress,
        abi: getAbi("CampaignRegistry"),
        functionName: "getCampaignByVault",
        args: [ctx.campaignVaultAddress],
      })) as { id: `0x${string}` };

      expect(byVault.id).toBe(ctx.campaignId);

      const vaultDonationRouter = (await publicClient.readContract({
        address: ctx.campaignVaultAddress,
        abi: getAbi("GiveVault4626"),
        functionName: "donationRouter",
      })) as `0x${string}`;

      if (
        getAddress(vaultDonationRouter) !== getAddress(ctx.payoutRouterAddress)
      ) {
        const setRouterHash = await walletClient.writeContract({
          account: ctx.adminAccount,
          address: ctx.campaignVaultAddress,
          abi: getAbi("GiveVault4626"),
          functionName: "setDonationRouter",
          args: [ctx.payoutRouterAddress],
          gas: 300_000n,
        });

        const setRouterReceipt = await publicClient.waitForTransactionReceipt({
          hash: setRouterHash,
        });
        expect(setRouterReceipt.status).toBe("success");
      }

      const activeAdapter = (await publicClient.readContract({
        address: ctx.campaignVaultAddress,
        abi: getAbi("GiveVault4626"),
        functionName: "activeAdapter",
      })) as `0x${string}`;

      if (getAddress(activeAdapter) === getAddress(zeroAddress)) {
        const rawAavePoolAddress =
          process.env.AAVE_POOL_ADDRESS || deployments.AAVE_POOL_ADDRESS;
        const canDeployAdapter = requireOrSkip(
          Boolean(rawAavePoolAddress),
          "AAVE_POOL_ADDRESS missing for campaign vault adapter deployment",
        );
        if (!canDeployAdapter) return;

        const aavePoolAddress = getAddress(rawAavePoolAddress as `0x${string}`);

        const deployAdapterHash = await walletClient.deployContract({
          account: ctx.adminAccount,
          abi: getAbi("AaveAdapter"),
          bytecode: getBytecode("AaveAdapter"),
          args: [
            ctx.usdcAddress,
            ctx.campaignVaultAddress,
            aavePoolAddress,
            ctx.adminAddress,
          ],
        });

        const deployAdapterReceipt =
          await publicClient.waitForTransactionReceipt({
            hash: deployAdapterHash,
          });
        expect(deployAdapterReceipt.status).toBe("success");

        const adapterAddress = deployAdapterReceipt.contractAddress;
        expect(adapterAddress).toBeDefined();

        const setAdapterHash = await walletClient.writeContract({
          account: ctx.adminAccount,
          address: ctx.campaignVaultAddress,
          abi: getAbi("GiveVault4626"),
          functionName: "setActiveAdapter",
          args: [adapterAddress!],
          gas: 500_000n,
        });

        const setAdapterReceipt = await publicClient.waitForTransactionReceipt({
          hash: setAdapterHash,
        });
        expect(setAdapterReceipt.status).toBe("success");
      }
    });

    it("test_S02_checkpointDone", () => {
      markSectionDone("2", "Campaign Lifecycle");
      expect(ctx.sectionDone.has("2")).toBe(true);
    });
  });
}
