// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {BaseDeployment} from "./base/BaseDeployment.sol";
import {ACLManager} from "../src/governance/ACLManager.sol";
import {GiveProtocolCore} from "../src/core/GiveProtocolCore.sol";
import {StrategyRegistry} from "../src/registry/StrategyRegistry.sol";
import {CampaignRegistry} from "../src/registry/CampaignRegistry.sol";
import {NGORegistry} from "../src/donation/NGORegistry.sol";
import {PayoutRouter} from "../src/payout/PayoutRouter.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {console} from "forge-std/console.sol";

/**
 * @title Deploy01_Infrastructure
 * @author GIVE Labs
 * @notice Phase 1: Deploy core protocol infrastructure
 * @dev Deploys:
 *      - ACLManager (UUPS proxy)
 *      - GiveProtocolCore (UUPS proxy)
 *      - StrategyRegistry (UUPS proxy)
 *      - CampaignRegistry (UUPS proxy)
 *      - NGORegistry (UUPS proxy)
 *      - PayoutRouter (UUPS proxy)
 *
 * Usage:
 *   forge script script/Deploy01_Infrastructure.s.sol:Deploy01_Infrastructure \
 *     --rpc-url $BASE_SEPOLIA_RPC_URL \
 *     --private-key $PRIVATE_KEY \
 *     --broadcast --verify
 */
contract Deploy01_Infrastructure is BaseDeployment {
    // Deployed contract instances
    ACLManager public aclManager;
    GiveProtocolCore public protocolCore;
    StrategyRegistry public strategyRegistry;
    CampaignRegistry public campaignRegistry;
    NGORegistry public ngoRegistry;
    PayoutRouter public payoutRouter;

    // Admin addresses
    address public admin;
    address public upgrader;
    address public treasury;

    // Protocol configuration
    uint256 public protocolFeeBps;

    function setUp() public override {
        super.setUp();

        // Load admin addresses from env
        admin = requireEnvAddress("ADMIN_ADDRESS");
        upgrader = getEnvAddressOr("UPGRADER_ADDRESS", admin); // Default to admin if not set
        treasury = requireEnvAddress("TREASURY_ADDRESS");

        // Load protocol configuration
        protocolFeeBps = getEnvUintOr("PROTOCOL_FEE_BPS", 100); // Default 1%

        console.log("Admin address:", admin);
        console.log("Upgrader address:", upgrader);
        console.log("Treasury address:", treasury);
        console.log("Protocol fee (bps):", protocolFeeBps);
    }

    function run() public {
        bool hasKey = bytes(vm.envOr("PRIVATE_KEY", string(""))).length > 0;
        if (hasKey) {
            uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
            startBroadcastWith(deployerPrivateKey);
        } else {
            startBroadcast(); // uses forge --account
        }
        // ========================================
        // STEP 1: Deploy ACLManager
        // ========================================
        console.log("\n[1/6] Deploying ACLManager...");

        ACLManager aclImpl = new ACLManager();
        bytes memory aclInitData = abi.encodeWithSelector(
            ACLManager.initialize.selector,
            admin, // initialSuperAdmin
            upgrader // upgrader
        );
        ERC1967Proxy aclProxy = new ERC1967Proxy(address(aclImpl), aclInitData);
        aclManager = ACLManager(address(aclProxy));

        console.log("ACLManager implementation:", address(aclImpl));
        console.log("ACLManager proxy:", address(aclManager));

        saveDeployment("ACLManagerImplementation", address(aclImpl));
        saveDeployment("ACLManager", address(aclManager));

        // ========================================
        // STEP 2: Deploy GiveProtocolCore
        // ========================================
        console.log("\n[2/6] Deploying GiveProtocolCore...");

        GiveProtocolCore coreImpl = new GiveProtocolCore();
        bytes memory coreInitData = abi.encodeWithSelector(GiveProtocolCore.initialize.selector, address(aclManager));
        ERC1967Proxy coreProxy = new ERC1967Proxy(address(coreImpl), coreInitData);
        protocolCore = GiveProtocolCore(address(coreProxy));

        console.log("GiveProtocolCore implementation:", address(coreImpl));
        console.log("GiveProtocolCore proxy:", address(protocolCore));

        saveDeployment("GiveProtocolCoreImplementation", address(coreImpl));
        saveDeployment("GiveProtocolCore", address(protocolCore));

        // ========================================
        // STEP 3: Deploy StrategyRegistry
        // ========================================
        console.log("\n[3/6] Deploying StrategyRegistry...");

        StrategyRegistry strategyImpl = new StrategyRegistry();
        bytes memory strategyInitData =
            abi.encodeWithSelector(StrategyRegistry.initialize.selector, address(aclManager));
        ERC1967Proxy strategyProxy = new ERC1967Proxy(address(strategyImpl), strategyInitData);
        strategyRegistry = StrategyRegistry(address(strategyProxy));

        console.log("StrategyRegistry implementation:", address(strategyImpl));
        console.log("StrategyRegistry proxy:", address(strategyRegistry));

        saveDeployment("StrategyRegistryImplementation", address(strategyImpl));
        saveDeployment("StrategyRegistry", address(strategyRegistry));

        // ========================================
        // STEP 4: Deploy CampaignRegistry
        // ========================================
        console.log("\n[4/6] Deploying CampaignRegistry...");

        CampaignRegistry campaignImpl = new CampaignRegistry();
        bytes memory campaignInitData = abi.encodeWithSelector(
            CampaignRegistry.initialize.selector,
            address(aclManager),
            address(strategyRegistry) // Campaign deposit/durations are constants in contract
        );
        ERC1967Proxy campaignProxy = new ERC1967Proxy(address(campaignImpl), campaignInitData);
        campaignRegistry = CampaignRegistry(payable(address(campaignProxy)));

        console.log("CampaignRegistry implementation:", address(campaignImpl));
        console.log("CampaignRegistry proxy:", address(campaignRegistry));
        console.log(
            "Note: Campaign submission deposit, min stake duration, and checkpoint duration are constants in the contract"
        );

        saveDeployment("CampaignRegistryImplementation", address(campaignImpl));
        saveDeployment("CampaignRegistry", address(campaignRegistry));

        // ========================================
        // STEP 5: Deploy NGORegistry
        // ========================================
        console.log("\n[5/6] Deploying NGORegistry...");

        NGORegistry ngoImpl = new NGORegistry();
        bytes memory ngoInitData = abi.encodeWithSelector(NGORegistry.initialize.selector, address(aclManager));
        ERC1967Proxy ngoProxy = new ERC1967Proxy(address(ngoImpl), ngoInitData);
        ngoRegistry = NGORegistry(address(ngoProxy));

        console.log("NGORegistry implementation:", address(ngoImpl));
        console.log("NGORegistry proxy:", address(ngoRegistry));

        saveDeployment("NGORegistryImplementation", address(ngoImpl));
        saveDeployment("NGORegistry", address(ngoRegistry));

        // ========================================
        // STEP 6: Deploy PayoutRouter
        // ========================================
        console.log("\n[6/6] Deploying PayoutRouter...");

        PayoutRouter routerImpl = new PayoutRouter();
        bytes memory routerInitData = abi.encodeWithSelector(
            PayoutRouter.initialize.selector,
            admin, // admin
            address(aclManager), // acl
            address(campaignRegistry), // campaignRegistry
            treasury, // feeRecipient
            treasury, // protocolTreasury (same as feeRecipient)
            protocolFeeBps // feeBps (max 1000 = 10%)
        );
        ERC1967Proxy routerProxy = new ERC1967Proxy(address(routerImpl), routerInitData);
        payoutRouter = PayoutRouter(address(routerProxy));

        console.log("PayoutRouter fee (bps):", protocolFeeBps);

        console.log("PayoutRouter implementation:", address(routerImpl));
        console.log("PayoutRouter proxy:", address(payoutRouter));

        saveDeployment("PayoutRouterImplementation", address(routerImpl));
        saveDeployment("PayoutRouter", address(payoutRouter));

        // ========================================
        // Finalize
        // ========================================
        finalizeDeployment();

        stopBroadcastIf();

        console.log("\n========================================");
        console.log("Phase 1 Complete: Infrastructure Deployed");
        console.log("========================================");
        console.log("Next step: Deploy02_VaultsAndAdapters.s.sol");
    }
}
