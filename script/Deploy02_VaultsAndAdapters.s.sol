// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {BaseDeployment} from "./base/BaseDeployment.sol";
import {GiveVault4626} from "../src/vault/GiveVault4626.sol";
import {CampaignVault4626} from "../src/vault/CampaignVault4626.sol";
import {CampaignVaultFactory} from "../src/factory/CampaignVaultFactory.sol";
import {AaveAdapter} from "../src/adapters/AaveAdapter.sol";
import {PendleAdapter} from "../src/adapters/kinds/PendleAdapter.sol";
import {StrategyManager} from "../src/manager/StrategyManager.sol";
import {ACLManager} from "../src/governance/ACLManager.sol";
import {GiveProtocolCore} from "../src/core/GiveProtocolCore.sol";
import {StrategyRegistry} from "../src/registry/StrategyRegistry.sol";
import {CampaignRegistry} from "../src/registry/CampaignRegistry.sol";
import {PayoutRouter} from "../src/payout/PayoutRouter.sol";
import {VaultModule} from "../src/modules/VaultModule.sol";
import {RiskModule} from "../src/modules/RiskModule.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {console} from "forge-std/console.sol";

/**
 * @title Deploy02_VaultsAndAdapters
 * @author GIVE Labs
 * @notice Phase 2: Deploy vaults, adapters, and strategy managers
 * @dev Deploys:
 *      - Vault implementations (GiveVault4626, CampaignVault4626)
 *      - CampaignVaultFactory
 *      - Main USDC vault (UUPS proxy)
 *      - Aave USDC adapter
 *      - Strategy manager for USDC vault
 *      - Risk profiles configuration
 *
 * Prerequisites:
 *   - Deploy01_Infrastructure must be completed
 *   - USDC and Aave Pool addresses must be set in .env
 *
 * Usage:
 *   forge script script/Deploy02_VaultsAndAdapters.s.sol:Deploy02_VaultsAndAdapters \
 *     --rpc-url $BASE_SEPOLIA_RPC_URL \
 *     --private-key $PRIVATE_KEY \
 *     --broadcast --verify
 */
contract Deploy02_VaultsAndAdapters is BaseDeployment {
    // Loaded from Deploy01
    ACLManager public aclManager;
    GiveProtocolCore public protocolCore;
    StrategyRegistry public strategyRegistry;
    CampaignRegistry public campaignRegistry;
    PayoutRouter public payoutRouter;

    // Deployed in this phase
    GiveVault4626 public giveVaultImpl;
    CampaignVault4626 public campaignVaultImpl;
    CampaignVaultFactory public vaultFactory;
    GiveVault4626 public usdcVault;
    AaveAdapter public aaveUsdcAdapter;
    PendleAdapter public pendleUsdcAdapter;
    StrategyManager public usdcStrategyManager;

    // External contracts
    address public usdcToken;
    address public aavePool;
    address public pendleRouter;
    address public pendleMarket;
    address public pendlePt;

    // Admin addresses
    address public admin;
    address public protocolAdmin;

    // Vault & risk configuration
    bytes32 public usdcVaultId;
    bytes32 public conservativeRiskId;
    bytes32 public aaveUsdcAdapterId;
    bytes32 public pendleUsdcAdapterId;
    bool public requireAaveAdapter;

    function setUp() public override {
        super.setUp();

        // Load from Deploy01
        aclManager = ACLManager(loadDeployment("ACLManager"));
        protocolCore = GiveProtocolCore(loadDeployment("GiveProtocolCore"));
        strategyRegistry = StrategyRegistry(loadDeployment("StrategyRegistry"));
        campaignRegistry = CampaignRegistry(loadDeployment("CampaignRegistry"));
        payoutRouter = PayoutRouter(loadDeployment("PayoutRouter"));

        // Load admin addresses
        admin = requireEnvAddress("ADMIN_ADDRESS");
        protocolAdmin = requireEnvAddress("PROTOCOL_ADMIN_ADDRESS");

        // Load external contracts (use env for real networks)
        usdcToken = getEnvAddressOr("USDC_ADDRESS", address(0));
        aavePool = getEnvAddressOr("AAVE_POOL_ADDRESS", address(0));
        pendleRouter = getEnvAddressOr("PENDLE_ROUTER_ADDRESS", address(0));
        pendleMarket = getEnvAddressOr("PENDLE_MARKET_ADDRESS", address(0));
        pendlePt = getEnvAddressOr("PENDLE_PT_ADDRESS", address(0));
        requireAaveAdapter = getEnvBoolOr("REQUIRE_AAVE_ADAPTER", true);

        require(admin != address(0), "ADMIN_ADDRESS cannot be zero");
        require(protocolAdmin != address(0), "PROTOCOL_ADMIN_ADDRESS cannot be zero");
        require(usdcToken != address(0), "USDC_ADDRESS not set in .env");
        if (requireAaveAdapter) {
            require(aavePool != address(0), "AAVE_POOL_ADDRESS required when REQUIRE_AAVE_ADAPTER=true");
        }

        // Generate deterministic IDs
        usdcVaultId = keccak256("vault.usdc.main");
        conservativeRiskId = keccak256("risk.conservative");
        aaveUsdcAdapterId = keccak256("adapter.aave.usdc");
        pendleUsdcAdapterId = keccak256("adapter.pendle.usdc");

        console.log("Loaded ACLManager:", address(aclManager));
        console.log("Loaded GiveProtocolCore:", address(protocolCore));
        console.log("Admin:", admin);
        console.log("Protocol Admin:", protocolAdmin);
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
        // STEP 1: Deploy Vault Implementations
        // ========================================
        console.log("\n[1/9] Deploying Vault Implementations...");

        giveVaultImpl = new GiveVault4626();
        campaignVaultImpl = new CampaignVault4626();

        console.log("GiveVault4626 implementation:", address(giveVaultImpl));
        console.log("CampaignVault4626 implementation:", address(campaignVaultImpl));

        saveDeployment("GiveVault4626Implementation", address(giveVaultImpl));
        saveDeployment("CampaignVault4626Implementation", address(campaignVaultImpl));

        // ========================================
        // STEP 2: Deploy CampaignVaultFactory (UUPS Proxy)
        // ========================================
        console.log("\n[2/9] Deploying CampaignVaultFactory...");

        CampaignVaultFactory factoryImpl = new CampaignVaultFactory();
        bytes memory factoryInitData = abi.encodeWithSelector(
            CampaignVaultFactory.initialize.selector,
            address(aclManager),
            address(campaignRegistry),
            address(strategyRegistry),
            address(payoutRouter),
            address(campaignVaultImpl)
        );
        ERC1967Proxy factoryProxy = new ERC1967Proxy(address(factoryImpl), factoryInitData);
        vaultFactory = CampaignVaultFactory(address(factoryProxy));

        console.log("CampaignVaultFactory implementation:", address(factoryImpl));
        console.log("CampaignVaultFactory proxy:", address(vaultFactory));

        saveDeployment("CampaignVaultFactoryImplementation", address(factoryImpl));
        saveDeployment("CampaignVaultFactory", address(vaultFactory));

        // ========================================
        // STEP 3: Grant Module Manager Roles
        // ========================================
        console.log("\n[3/9] Granting Module Manager Roles...");

        // Create and grant module manager roles (required for protocolCore.configure* calls)
        bytes32 VAULT_MODULE_MANAGER_ROLE = keccak256("VAULT_MODULE_MANAGER_ROLE");
        bytes32 ADAPTER_MODULE_MANAGER_ROLE = keccak256("ADAPTER_MODULE_MANAGER_ROLE");
        bytes32 RISK_MODULE_MANAGER_ROLE = keccak256("RISK_MODULE_MANAGER_ROLE");

        // Create roles if they don't exist
        if (!aclManager.roleExists(VAULT_MODULE_MANAGER_ROLE)) {
            aclManager.createRole(VAULT_MODULE_MANAGER_ROLE, admin);
        }
        if (!aclManager.roleExists(ADAPTER_MODULE_MANAGER_ROLE)) {
            aclManager.createRole(ADAPTER_MODULE_MANAGER_ROLE, admin);
        }
        if (!aclManager.roleExists(RISK_MODULE_MANAGER_ROLE)) {
            aclManager.createRole(RISK_MODULE_MANAGER_ROLE, admin);
        }

        // Grant roles to protocol admin
        aclManager.grantRole(VAULT_MODULE_MANAGER_ROLE, protocolAdmin);
        aclManager.grantRole(ADAPTER_MODULE_MANAGER_ROLE, protocolAdmin);
        aclManager.grantRole(RISK_MODULE_MANAGER_ROLE, protocolAdmin);

        // Also grant to deployer for this script
        address deployer = msg.sender;
        aclManager.grantRole(VAULT_MODULE_MANAGER_ROLE, deployer);
        aclManager.grantRole(ADAPTER_MODULE_MANAGER_ROLE, deployer);
        aclManager.grantRole(RISK_MODULE_MANAGER_ROLE, deployer);

        console.log("Module manager roles granted to protocolAdmin and deployer");

        // Grant VAULT_MANAGER_ROLE to CampaignVaultFactory
        // (Required for factory to call payoutRouter.registerCampaignVault)
        bytes32 VAULT_MANAGER_ROLE = keccak256("VAULT_MANAGER_ROLE");
        if (!aclManager.roleExists(VAULT_MANAGER_ROLE)) {
            aclManager.createRole(VAULT_MANAGER_ROLE, admin);
        }
        aclManager.grantRole(VAULT_MANAGER_ROLE, address(vaultFactory));
        console.log("Granted VAULT_MANAGER_ROLE to CampaignVaultFactory");

        // ========================================
        // STEP 4: Configure Risk Profiles
        // ========================================
        console.log("\n[4/9] Configuring Risk Profiles...");

        // Conservative risk profile
        protocolCore.configureRisk(
            conservativeRiskId,
            RiskModule.RiskConfigInput({
                id: conservativeRiskId,
                ltvBps: uint16(getEnvUintOr("CONSERVATIVE_LTV_BPS", 1000)), // 10%
                liquidationThresholdBps: uint16(getEnvUintOr("CONSERVATIVE_LIQUIDATION_THRESHOLD_BPS", 1200)), // 12%
                liquidationPenaltyBps: 500, // 5%
                borrowCapBps: 3000, // 30%
                depositCapBps: 5000, // 50%
                dataHash: bytes32(0),
                maxDeposit: getEnvUintOr("CONSERVATIVE_MAX_DEPOSIT", 1_000_000e6), // $1M
                maxBorrow: getEnvUintOr("CONSERVATIVE_MAX_BORROW", 100_000e6) // $100K
            })
        );

        console.log("Conservative risk profile configured");
        saveDeploymentBytes32("ConservativeRiskId", conservativeRiskId);

        // ========================================
        // STEP 5: Validate USDC Token
        // ========================================
        console.log("\n[5/9] Validating USDC Token...");

        console.log("Using USDC at:", usdcToken);
        saveDeployment("USDCAddress", usdcToken);

        // ========================================
        // STEP 6: Deploy Main USDC Vault
        // ========================================
        console.log("\n[6/9] Deploying Main USDC Vault...");

        bytes memory usdcVaultInitData = abi.encodeWithSelector(
            GiveVault4626.initialize.selector,
            usdcToken, // asset
            "GIVE USDC Vault", // name
            "gvUSDC", // symbol
            admin, // admin
            address(aclManager), // acl
            address(giveVaultImpl) // implementation
        );

        ERC1967Proxy usdcVaultProxy = new ERC1967Proxy(address(giveVaultImpl), usdcVaultInitData);
        usdcVault = GiveVault4626(payable(address(usdcVaultProxy)));

        console.log("USDC Vault proxy:", address(usdcVault));

        saveDeployment("USDCVault", address(usdcVault));
        saveDeploymentBytes32("USDCVaultId", usdcVaultId);

        // Grant VAULT_MANAGER_ROLE to protocolCore for risk sync
        // (Reusing VAULT_MANAGER_ROLE from Step 3)
        usdcVault.grantRole(VAULT_MANAGER_ROLE, address(protocolCore));

        // ========================================
        // STEP 7: Register USDC Vault in Protocol
        // ========================================
        console.log("\n[7/9] Registering USDC Vault in Protocol...");

        protocolCore.configureVault(
            usdcVaultId,
            VaultModule.VaultConfigInput({
                id: usdcVaultId,
                proxy: address(usdcVault),
                implementation: address(giveVaultImpl),
                asset: usdcToken,
                adapterId: bytes32(0), // Set later
                donationModuleId: bytes32(0),
                riskId: conservativeRiskId,
                cashBufferBps: uint16(getEnvUintOr("DEFAULT_CASH_BUFFER_BPS", 1000)), // 10%
                slippageBps: uint16(getEnvUintOr("DEFAULT_SLIPPAGE_BPS", 100)), // 1%
                maxLossBps: uint16(getEnvUintOr("DEFAULT_MAX_LOSS_BPS", 50)) // 0.5%
            })
        );

        // Assign risk profile to vault
        protocolCore.assignVaultRisk(usdcVaultId, conservativeRiskId);

        console.log("USDC Vault registered and configured");

        // ========================================
        // STEP 8: Deploy Aave USDC Adapter (if Aave available)
        // ========================================
        console.log("\n[8/9] Deploying Aave USDC Adapter...");

        if (aavePool != address(0)) {
            aaveUsdcAdapter = new AaveAdapter(usdcToken, address(usdcVault), aavePool, admin);

            console.log("Aave USDC Adapter:", address(aaveUsdcAdapter));

            saveDeployment("AaveUSDCAdapter", address(aaveUsdcAdapter));
            saveDeploymentBytes32("AaveUSDCAdapterId", aaveUsdcAdapterId);
        } else {
            console.log("Skipping Aave adapter (AAVE_POOL_ADDRESS not set)");
        }

        if (pendleRouter != address(0) && pendleMarket != address(0) && pendlePt != address(0)) {
            pendleUsdcAdapter = new PendleAdapter(
                pendleUsdcAdapterId, usdcToken, address(usdcVault), pendleRouter, pendleMarket, pendlePt
            );

            console.log("Pendle USDC Adapter:", address(pendleUsdcAdapter));

            saveDeployment("PendleUSDCAdapter", address(pendleUsdcAdapter));
            saveDeploymentBytes32("PendleUSDCAdapterId", pendleUsdcAdapterId);
        } else {
            console.log(
                "Skipping Pendle adapter (PENDLE_ROUTER_ADDRESS / PENDLE_MARKET_ADDRESS / PENDLE_PT_ADDRESS not set)"
            );
        }

        // ========================================
        // STEP 9: Deploy Strategy Manager
        // ========================================
        console.log("\n[9/9] Deploying Strategy Manager for USDC Vault...");

        usdcStrategyManager =
            new StrategyManager(address(usdcVault), admin, address(strategyRegistry), address(campaignRegistry));

        console.log("USDC Strategy Manager:", address(usdcStrategyManager));

        saveDeployment("USDCStrategyManager", address(usdcStrategyManager));

        // Grant VAULT_MANAGER_ROLE to StrategyManager
        usdcVault.grantRole(VAULT_MANAGER_ROLE, address(usdcStrategyManager));
        usdcVault.grantRole(VAULT_MANAGER_ROLE, protocolAdmin);

        console.log("Granted VAULT_MANAGER_ROLE to StrategyManager & protocolAdmin");

        // ========================================
        // Finalize
        // ========================================
        finalizeDeployment();

        stopBroadcastIf();

        console.log("\n========================================");
        console.log("Phase 2 Complete: Vaults & Adapters Deployed");
        console.log("========================================");
        console.log("Main USDC Vault:", address(usdcVault));
        if (aavePool != address(0)) {
            console.log("Aave Adapter:", address(aaveUsdcAdapter));
        }
        if (address(pendleUsdcAdapter) != address(0)) {
            console.log("Pendle Adapter:", address(pendleUsdcAdapter));
        }
        console.log("Strategy Manager:", address(usdcStrategyManager));
        console.log("\nNext step: Deploy03_Initialize.s.sol");
    }
}
