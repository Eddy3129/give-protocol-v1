// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {BaseDeployment} from "./base/BaseDeployment.sol";
import {ACLManager} from "../src/governance/ACLManager.sol";
import {StrategyRegistry} from "../src/registry/StrategyRegistry.sol";
import {StrategyManager} from "../src/manager/StrategyManager.sol";
import {AaveAdapter} from "../src/adapters/AaveAdapter.sol";
import {PendleAdapter} from "../src/adapters/kinds/PendleAdapter.sol";
import {GiveVault4626} from "../src/vault/GiveVault4626.sol";
import {PayoutRouter} from "../src/payout/PayoutRouter.sol";
import {console} from "forge-std/console.sol";

/**
 * @title Deploy03_Initialize
 * @author GIVE Labs
 * @notice Phase 3: Initialize protocol with roles, strategies, and configuration
 * @dev Performs:
 *      - Grant all protocol roles to admin addresses
 *      - Register initial strategies (Aave USDC)
 *      - Approve and activate adapters on vaults
 *      - Configure protocol parameters
 *
 * Prerequisites:
 *   - Deploy01_Infrastructure must be completed
 *   - Deploy02_VaultsAndAdapters must be completed
 *
 * Usage:
 *   forge script script/Deploy03_Initialize.s.sol:Deploy03_Initialize \
 *     --rpc-url $BASE_SEPOLIA_RPC_URL \
 *     --private-key $PRIVATE_KEY \
 *     --broadcast
 */
contract Deploy03_Initialize is BaseDeployment {
    // Loaded contracts
    ACLManager public aclManager;
    StrategyRegistry public strategyRegistry;
    StrategyManager public usdcStrategyManager;
    GiveVault4626 public usdcVault;
    PayoutRouter public payoutRouter;
    address public campaignVaultFactory;
    AaveAdapter public aaveUsdcAdapter;
    PendleAdapter public pendleUsdcAdapter;

    // Admin addresses
    address public admin;
    address public protocolAdmin;
    address public strategyAdmin;
    address public campaignAdmin;
    address public campaignCreator;
    address public checkpointCouncil;

    // Canonical role hashes
    bytes32 public ROLE_UPGRADER;
    bytes32 public ROLE_PROTOCOL_ADMIN;
    bytes32 public ROLE_STRATEGY_ADMIN;
    bytes32 public ROLE_CAMPAIGN_ADMIN;
    bytes32 public ROLE_CAMPAIGN_CREATOR;
    bytes32 public ROLE_CAMPAIGN_CURATOR;
    bytes32 public ROLE_CHECKPOINT_COUNCIL;

    // Strategy IDs
    bytes32 public aaveUsdcStrategyId;
    bytes32 public pendleUsdcStrategyId;

    function setUp() public override {
        super.setUp();

        // Load deployed contracts
        aclManager = ACLManager(loadDeployment("ACLManager"));
        strategyRegistry = StrategyRegistry(loadDeployment("StrategyRegistry"));
        usdcStrategyManager = StrategyManager(loadDeployment("USDCStrategyManager"));
        usdcVault = GiveVault4626(payable(loadDeployment("USDCVault")));
        payoutRouter = PayoutRouter(payable(loadDeployment("PayoutRouter")));
        campaignVaultFactory = loadDeployment("CampaignVaultFactory");

        // Try to load Aave adapter (may not exist if Aave not available)
        aaveUsdcAdapter = AaveAdapter(loadDeploymentOrZero("AaveUSDCAdapter"));
        pendleUsdcAdapter = PendleAdapter(loadDeploymentOrZero("PendleUSDCAdapter"));

        // Load admin addresses from env
        admin = requireEnvAddress("ADMIN_ADDRESS");
        protocolAdmin = requireEnvAddress("PROTOCOL_ADMIN_ADDRESS");
        strategyAdmin = requireEnvAddress("STRATEGY_ADMIN_ADDRESS");
        campaignAdmin = requireEnvAddress("CAMPAIGN_ADMIN_ADDRESS");
        campaignCreator = getEnvAddressOr("CAMPAIGN_CREATOR_ADDRESS", campaignAdmin);
        checkpointCouncil = getEnvAddressOr("CHECKPOINT_COUNCIL_ADDRESS", campaignAdmin);

        require(admin != address(0), "ADMIN_ADDRESS cannot be zero");
        require(protocolAdmin != address(0), "PROTOCOL_ADMIN_ADDRESS cannot be zero");
        require(strategyAdmin != address(0), "STRATEGY_ADMIN_ADDRESS cannot be zero");
        require(campaignAdmin != address(0), "CAMPAIGN_ADMIN_ADDRESS cannot be zero");
        require(campaignVaultFactory != address(0), "CampaignVaultFactory deployment missing");

        // Define canonical role hashes
        ROLE_UPGRADER = keccak256("ROLE_UPGRADER");
        ROLE_PROTOCOL_ADMIN = keccak256("ROLE_PROTOCOL_ADMIN");
        ROLE_STRATEGY_ADMIN = keccak256("ROLE_STRATEGY_ADMIN");
        ROLE_CAMPAIGN_ADMIN = keccak256("ROLE_CAMPAIGN_ADMIN");
        ROLE_CAMPAIGN_CREATOR = keccak256("ROLE_CAMPAIGN_CREATOR");
        ROLE_CAMPAIGN_CURATOR = keccak256("ROLE_CAMPAIGN_CURATOR");
        ROLE_CHECKPOINT_COUNCIL = keccak256("ROLE_CHECKPOINT_COUNCIL");

        // Strategy IDs
        aaveUsdcStrategyId = keccak256("strategy.aave.usdc");
        pendleUsdcStrategyId = keccak256("strategy.pendle.usdc");

        console.log("Loaded ACLManager:", address(aclManager));
        console.log("Admin:", admin);
        console.log("Protocol Admin:", protocolAdmin);
        console.log("Strategy Admin:", strategyAdmin);
        console.log("Campaign Admin:", campaignAdmin);
        console.log("Campaign Vault Factory:", campaignVaultFactory);
    }

    function run() public {
        bool hasKey = bytes(vm.envOr("PRIVATE_KEY", string(""))).length > 0;
        bool allowDefaultBroadcast = getEnvBoolOr("ALLOW_DEFAULT_BROADCAST", false);
        if (hasKey) {
            uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
            address broadcaster = vm.addr(deployerPrivateKey);
            require(broadcaster == admin, "PRIVATE_KEY signer must equal ADMIN_ADDRESS");
            console.log("Broadcast signer:", broadcaster);
            startBroadcastWith(deployerPrivateKey);
        } else {
            require(
                allowDefaultBroadcast,
                "PRIVATE_KEY required. Set ALLOW_DEFAULT_BROADCAST=true only for controlled local runs"
            );
            console.log("WARNING: using default broadcast signer (no PRIVATE_KEY)");
            startBroadcast();
        }
        // ========================================
        // STEP 1: Create Canonical Roles
        // ========================================
        console.log("\n[1/6] Creating Canonical Protocol Roles...");

        // Create roles (only if not already created)
        if (!aclManager.roleExists(ROLE_UPGRADER)) {
            aclManager.createRole(ROLE_UPGRADER, admin);
            console.log("Created ROLE_UPGRADER");
        }

        if (!aclManager.roleExists(ROLE_PROTOCOL_ADMIN)) {
            aclManager.createRole(ROLE_PROTOCOL_ADMIN, admin);
            console.log("Created ROLE_PROTOCOL_ADMIN");
        }

        if (!aclManager.roleExists(ROLE_STRATEGY_ADMIN)) {
            aclManager.createRole(ROLE_STRATEGY_ADMIN, admin);
            console.log("Created ROLE_STRATEGY_ADMIN");
        }

        if (!aclManager.roleExists(ROLE_CAMPAIGN_ADMIN)) {
            aclManager.createRole(ROLE_CAMPAIGN_ADMIN, admin);
            console.log("Created ROLE_CAMPAIGN_ADMIN");
        }

        if (!aclManager.roleExists(ROLE_CAMPAIGN_CREATOR)) {
            aclManager.createRole(ROLE_CAMPAIGN_CREATOR, campaignAdmin);
            console.log("Created ROLE_CAMPAIGN_CREATOR");
        }

        if (!aclManager.roleExists(ROLE_CAMPAIGN_CURATOR)) {
            aclManager.createRole(ROLE_CAMPAIGN_CURATOR, campaignAdmin);
            console.log("Created ROLE_CAMPAIGN_CURATOR");
        }

        if (!aclManager.roleExists(ROLE_CHECKPOINT_COUNCIL)) {
            aclManager.createRole(ROLE_CHECKPOINT_COUNCIL, campaignAdmin);
            console.log("Created ROLE_CHECKPOINT_COUNCIL");
        }

        console.log("All canonical roles created");

        // ========================================
        // STEP 2: Grant Roles to Admin Addresses
        // ========================================
        console.log("\n[2/6] Granting Roles to Admins...");

        // Grant upgrader role
        if (!aclManager.hasRole(ROLE_UPGRADER, admin)) {
            aclManager.grantRole(ROLE_UPGRADER, admin);
            console.log("Granted ROLE_UPGRADER to admin");
        }

        // Grant protocol admin role
        if (!aclManager.hasRole(ROLE_PROTOCOL_ADMIN, protocolAdmin)) {
            aclManager.grantRole(ROLE_PROTOCOL_ADMIN, protocolAdmin);
            console.log("Granted ROLE_PROTOCOL_ADMIN to protocolAdmin");
        }

        // Grant strategy admin role
        if (!aclManager.hasRole(ROLE_STRATEGY_ADMIN, strategyAdmin)) {
            aclManager.grantRole(ROLE_STRATEGY_ADMIN, strategyAdmin);
            console.log("Granted ROLE_STRATEGY_ADMIN to strategyAdmin");
        }

        // Factory needs canonical roles for campaign vault lifecycle calls
        if (!aclManager.hasRole(ROLE_CAMPAIGN_ADMIN, campaignVaultFactory)) {
            aclManager.grantRole(ROLE_CAMPAIGN_ADMIN, campaignVaultFactory);
            console.log("Granted ROLE_CAMPAIGN_ADMIN to CampaignVaultFactory");
        }
        if (!aclManager.hasRole(ROLE_STRATEGY_ADMIN, campaignVaultFactory)) {
            aclManager.grantRole(ROLE_STRATEGY_ADMIN, campaignVaultFactory);
            console.log("Granted ROLE_STRATEGY_ADMIN to CampaignVaultFactory");
        }

        // Grant campaign roles
        if (!aclManager.hasRole(ROLE_CAMPAIGN_ADMIN, campaignAdmin)) {
            aclManager.grantRole(ROLE_CAMPAIGN_ADMIN, campaignAdmin);
        }
        if (!aclManager.hasRole(ROLE_CAMPAIGN_CREATOR, campaignCreator)) {
            aclManager.grantRole(ROLE_CAMPAIGN_CREATOR, campaignCreator);
        }
        if (!aclManager.hasRole(ROLE_CAMPAIGN_CURATOR, campaignAdmin)) {
            aclManager.grantRole(ROLE_CAMPAIGN_CURATOR, campaignAdmin);
        }
        if (!aclManager.hasRole(ROLE_CHECKPOINT_COUNCIL, checkpointCouncil)) {
            aclManager.grantRole(ROLE_CHECKPOINT_COUNCIL, checkpointCouncil);
        }

        console.log("Granted ROLE_CAMPAIGN_ADMIN to campaignAdmin");
        console.log("Granted ROLE_CAMPAIGN_CREATOR to campaignCreator");
        console.log("Granted ROLE_CAMPAIGN_CURATOR to campaignAdmin");
        console.log("Granted ROLE_CHECKPOINT_COUNCIL to checkpointCouncil");

        // ========================================
        // STEP 3: Register Initial Strategies
        // ========================================
        console.log("\n[3/6] Registering Initial Strategies...");

        if (address(aaveUsdcAdapter) != address(0)) {
            // Register Aave USDC strategy
            strategyRegistry.registerStrategy(
                StrategyRegistry.StrategyInput({
                    id: aaveUsdcStrategyId,
                    adapter: address(aaveUsdcAdapter),
                    riskTier: keccak256("LOW"),
                    maxTvl: 10_000_000e6, // $10M max TVL
                    metadataHash: keccak256("ipfs://QmAaveUSDC")
                })
            );

            console.log("Registered Aave USDC Strategy");
            console.log("Strategy ID:", vm.toString(aaveUsdcStrategyId));
            console.log("Adapter:", address(aaveUsdcAdapter));

            saveDeploymentBytes32("AaveUSDCStrategyId", aaveUsdcStrategyId);
        } else {
            console.log("Skipping Aave strategy (adapter not deployed)");
        }

        if (address(pendleUsdcAdapter) != address(0)) {
            strategyRegistry.registerStrategy(
                StrategyRegistry.StrategyInput({
                    id: pendleUsdcStrategyId,
                    adapter: address(pendleUsdcAdapter),
                    riskTier: keccak256("MEDIUM"),
                    maxTvl: 5_000_000e6,
                    metadataHash: keccak256("ipfs://QmPendleUSDC")
                })
            );

            console.log("Registered Pendle USDC Strategy");
            console.log("Strategy ID:", vm.toString(pendleUsdcStrategyId));
            console.log("Adapter:", address(pendleUsdcAdapter));

            saveDeploymentBytes32("PendleUSDCStrategyId", pendleUsdcStrategyId);
        } else {
            console.log("Skipping Pendle strategy (adapter not deployed)");
        }

        // ========================================
        // STEP 4: Approve & Activate Adapters
        // ========================================
        console.log("\n[4/6] Approving and Activating Adapters...");

        if (address(aaveUsdcAdapter) != address(0)) {
            // Approve Aave adapter on USDC vault
            usdcStrategyManager.setAdapterApproval(address(aaveUsdcAdapter), true);
            console.log("Approved Aave adapter on USDC vault");

            // Set as active adapter
            usdcStrategyManager.setActiveAdapter(address(aaveUsdcAdapter));
            console.log("Activated Aave adapter on USDC vault");

            // Enable auto-rebalance
            bool autoRebalance = getEnvBoolOr("AUTO_REBALANCE_ENABLED", true);
            usdcStrategyManager.setAutoRebalanceEnabled(autoRebalance);
            console.log("Auto-rebalance enabled:", autoRebalance);

            // Set rebalance interval
            uint256 rebalanceInterval = getEnvUintOr("REBALANCE_INTERVAL", 1 days);
            usdcStrategyManager.setRebalanceInterval(rebalanceInterval);
            console.log("Rebalance interval:", rebalanceInterval, "seconds");
        }

        if (address(pendleUsdcAdapter) != address(0)) {
            usdcStrategyManager.setAdapterApproval(address(pendleUsdcAdapter), true);
            console.log("Approved Pendle adapter on USDC vault");

            bool usePendleAsActive = getEnvBoolOr("USE_PENDLE_AS_ACTIVE", false);
            if (usePendleAsActive) {
                usdcStrategyManager.setActiveAdapter(address(pendleUsdcAdapter));
                console.log("Activated Pendle adapter on USDC vault");
            }
        }

        // ========================================
        // STEP 5: Wire Vault ↔ PayoutRouter
        // ========================================
        console.log("\n[5/6] Wiring Vault to PayoutRouter...");

        // setDonationRouter — vault calls payoutRouter.updateUserShares on every deposit/withdraw
        // and transfers harvested yield to payoutRouter.recordYield. Without this, the router
        // never tracks shares and yield distribution is completely bypassed.
        if (usdcVault.donationRouter() != address(payoutRouter)) {
            usdcVault.setDonationRouter(address(payoutRouter));
            console.log("setDonationRouter -> PayoutRouter:", address(payoutRouter));
        } else {
            console.log("donationRouter already set");
        }

        // setAuthorizedCaller — payoutRouter.updateUserShares and recordYield are gated behind
        // onlyAuthorized. The vault must be an authorized caller or neither call succeeds.
        // PayoutRouter.setAuthorizedCaller requires VAULT_MANAGER_ROLE. The deployer holds
        // DEFAULT_ADMIN_ROLE on the router (granted in initialize), so we grant ourselves the
        // role, perform the wiring, then optionally leave the role in place for future ops.
        if (!payoutRouter.authorizedCallers(address(usdcVault))) {
            bytes32 VAULT_MANAGER_ROLE = keccak256("VAULT_MANAGER_ROLE");
            // Use admin (= wallet signer from ADMIN_ADDRESS). In forge scripts,
            // msg.sender is the default runner (0x1804...), not the broadcast wallet.
            if (!aclManager.hasRole(VAULT_MANAGER_ROLE, admin)) {
                aclManager.grantRole(VAULT_MANAGER_ROLE, admin);
                console.log("Granted VAULT_MANAGER_ROLE to admin on ACLManager");
            }
            payoutRouter.setAuthorizedCaller(address(usdcVault), true);
            console.log("setAuthorizedCaller(USDCVault) = true");
        } else {
            console.log("USDCVault already authorized on PayoutRouter");
        }

        // ========================================
        // STEP 6: Save Configuration
        // ========================================
        console.log("\n[6/6] Saving Final Configuration...");

        // Save role hashes for future reference
        saveDeploymentBytes32("ROLE_UPGRADER", ROLE_UPGRADER);
        saveDeploymentBytes32("ROLE_PROTOCOL_ADMIN", ROLE_PROTOCOL_ADMIN);
        saveDeploymentBytes32("ROLE_STRATEGY_ADMIN", ROLE_STRATEGY_ADMIN);
        saveDeploymentBytes32("ROLE_CAMPAIGN_ADMIN", ROLE_CAMPAIGN_ADMIN);
        saveDeploymentBytes32("ROLE_CAMPAIGN_CREATOR", ROLE_CAMPAIGN_CREATOR);
        saveDeploymentBytes32("ROLE_CAMPAIGN_CURATOR", ROLE_CAMPAIGN_CURATOR);
        saveDeploymentBytes32("ROLE_CHECKPOINT_COUNCIL", ROLE_CHECKPOINT_COUNCIL);

        // Save admin addresses
        saveDeployment("AdminAddress", admin);
        saveDeployment("ProtocolAdminAddress", protocolAdmin);
        saveDeployment("StrategyAdminAddress", strategyAdmin);
        saveDeployment("CampaignAdminAddress", campaignAdmin);

        console.log("Configuration saved");

        // ========================================
        // Finalize
        // ========================================
        finalizeDeployment();

        stopBroadcastIf();

        console.log("\n========================================");
        console.log("Phase 3 Complete: Protocol Initialized");
        console.log("========================================");
        console.log("All roles granted");
        if (address(aaveUsdcAdapter) != address(0)) {
            console.log("Aave USDC strategy registered and activated");
        }
        if (address(pendleUsdcAdapter) != address(0)) {
            console.log("Pendle USDC strategy registered and approved");
        }
        console.log("\nProtocol deployment complete!");
        console.log("Next steps:");
        console.log("1. Use operations scripts to add campaigns");
        console.log("2. Use Upgrade.s.sol for contract upgrades");
    }
}
