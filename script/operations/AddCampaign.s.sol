// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {BaseDeployment} from "../base/BaseDeployment.sol";
import {CampaignRegistry} from "../../src/registry/CampaignRegistry.sol";
import {CampaignVaultFactory} from "../../src/factory/CampaignVaultFactory.sol";
import {PayoutRouter} from "../../src/payout/PayoutRouter.sol";
import {console} from "forge-std/console.sol";

/**
 * @title AddCampaign
 * @author GIVE Labs
 * @notice Standalone script to submit and approve a campaign
 * @dev Usage:
 *   1. Set campaign parameters in .env or pass via command line
 *   2. Run script to submit campaign
 *   3. Approve campaign (requires CAMPAIGN_ADMIN role)
 *   4. Deploy campaign vault
 *
 * Example:
 *   forge script script/operations/AddCampaign.s.sol:AddCampaign \
 *     --rpc-url $BASE_SEPOLIA_RPC_URL \
 *     --private-key $PRIVATE_KEY \
 *     --broadcast
 */
contract AddCampaign is BaseDeployment {
    CampaignRegistry public campaignRegistry;
    CampaignVaultFactory public vaultFactory;
    PayoutRouter public payoutRouter;

    // Campaign parameters
    string public campaignName;
    bytes32 public campaignId;
    address public payoutRecipient;
    bytes32 public strategyId;
    uint256 public targetStake;
    uint256 public minStake;
    uint256 public fundraisingDuration;

    address public campaignCreator;
    address public campaignAdmin;

    function setUp() public override {
        super.setUp();

        // Load contracts
        campaignRegistry = CampaignRegistry(loadDeployment("CampaignRegistry"));
        vaultFactory = CampaignVaultFactory(loadDeployment("CampaignVaultFactory"));
        payoutRouter = PayoutRouter(loadDeployment("PayoutRouter"));

        // Load admins
        campaignCreator = requireEnvAddress("CAMPAIGN_CREATOR_ADDRESS");
        campaignAdmin = requireEnvAddress("CAMPAIGN_ADMIN_ADDRESS");

        // Load campaign parameters from env
        campaignName = requireEnv("CAMPAIGN_NAME");
        campaignId = keccak256(bytes(campaignName));
        payoutRecipient = requireEnvAddress("CAMPAIGN_PAYOUT_RECIPIENT");
        strategyId = loadDeploymentBytes32("CAMPAIGN_STRATEGY_ID"); // e.g., AaveUSDCStrategyId
        targetStake = requireEnvUint("CAMPAIGN_TARGET_STAKE");
        minStake = requireEnvUint("CAMPAIGN_MIN_STAKE");
        fundraisingDuration = getEnvUintOr("CAMPAIGN_DURATION", 30 days);

        console.log("Campaign Name:", campaignName);
        console.log("Campaign ID:", vm.toString(campaignId));
        console.log("Payout Recipient:", payoutRecipient);
        console.log("Target Stake:", targetStake);
    }

    function run() public {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");

        startBroadcastWith(deployerPrivateKey);

        // ========================================
        // STEP 1: Submit Campaign
        // ========================================
        console.log("\n[1/3] Submitting Campaign...");

        // Campaign submission deposit is a constant in CampaignRegistry (0.005 ETH)
        uint256 submissionDeposit = 0.005 ether;
        console.log("Submission deposit required:", submissionDeposit);

        campaignRegistry.submitCampaign{value: submissionDeposit}(
            CampaignRegistry.CampaignInput({
                id: campaignId,
                payoutRecipient: payoutRecipient,
                strategyId: strategyId,
                metadataHash: keccak256(bytes(campaignName)),
                metadataCID: campaignName, // Replace with actual IPFS CID
                targetStake: targetStake,
                minStake: minStake,
                fundraisingStart: uint64(block.timestamp),
                // Safe: timestamp + duration fits in uint64 (valid until year 584 billion)
                // forge-lint: disable-next-line(unsafe-typecast)
                fundraisingEnd: uint64(block.timestamp + fundraisingDuration)
            })
        );

        console.log("Campaign submitted");

        // ========================================
        // STEP 2: Approve Campaign (requires CAMPAIGN_ADMIN)
        // ========================================
        console.log("\n[2/3] Approving Campaign...");

        // Note: This requires the transaction sender to have CAMPAIGN_ADMIN role
        campaignRegistry.approveCampaign(campaignId, campaignAdmin);

        console.log("Campaign approved");

        // ========================================
        // STEP 3: Deploy Campaign Vault
        // ========================================
        console.log("\n[3/3] Deploying Campaign Vault...");

        // Get asset address and admin from env
        address asset = requireEnvAddress("USDC_ADDRESS");
        address vaultAdmin = getEnvAddressOr("VAULT_ADMIN_ADDRESS", campaignAdmin);
        bytes32 lockProfile = getEnvBytes32Or("LOCK_PROFILE_ID", bytes32(0));

        address campaignVault = vaultFactory.deployCampaignVault(
            CampaignVaultFactory.DeployParams({
                campaignId: campaignId,
                strategyId: strategyId,
                lockProfile: lockProfile,
                asset: asset,
                admin: vaultAdmin,
                name: string.concat("GIVE ", campaignName, " Vault"),
                symbol: string.concat("cv", campaignName)
            })
        );

        console.log("Campaign vault deployed at:", campaignVault);

        // Save campaign info
        saveDeploymentBytes32(string.concat("Campaign_", campaignName, "_Id"), campaignId);
        saveDeployment(string.concat("Campaign_", campaignName, "_Vault"), campaignVault);

        finalizeDeployment();

        stopBroadcastIf();

        console.log("\n========================================");
        console.log("Campaign Successfully Added");
        console.log("========================================");
        console.log("Campaign ID:", vm.toString(campaignId));
        console.log("Vault Address:", campaignVault);
        console.log("Payout Recipient:", payoutRecipient);
        console.log("\nUsers can now deposit to vault:", campaignVault);
    }
}
