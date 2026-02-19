// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Base01_DeployCore} from "./Base01_DeployCore.t.sol";
import {GiveProtocolCore} from "../../src/core/GiveProtocolCore.sol";
import {StrategyManager} from "../../src/manager/StrategyManager.sol";
import {GiveVault4626} from "../../src/vault/GiveVault4626.sol";
import {CampaignVault4626} from "../../src/vault/CampaignVault4626.sol";
import {AaveAdapter} from "../../src/adapters/AaveAdapter.sol";
import {CompoundingAdapter} from "../../src/adapters/kinds/CompoundingAdapter.sol";
import {PendleAdapter} from "../../src/adapters/kinds/PendleAdapter.sol";
import {MockYieldAdapter} from "../../src/mocks/MockYieldAdapter.sol";
import {MockAavePool} from "../../src/mocks/MockAavePool.sol";
import {RiskModule} from "../../src/modules/RiskModule.sol";
import {VaultModule} from "../../src/modules/VaultModule.sol";
import {AdapterModule} from "../../src/modules/AdapterModule.sol";
import {GiveTypes} from "../../src/types/GiveTypes.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

/**
 * @title Base02_DeployVaultsAndAdapters
 * @author GIVE Labs
 * @notice Comprehensive test environment with real vaults and adapters
 * @dev Inherits Base01 and adds:
 *      - GiveProtocolCore (UUPS proxy)
 *      - Real GiveVault4626 for general donations
 *      - Real CampaignVault4626 for campaigns
 *      - Real yield adapters (Aave, Compounding, Mock)
 *      - StrategyManagers for vault orchestration
 *      - Risk profiles and configurations
 *
 *      NO MOCKS except for external dependencies (Aave pool)
 */
contract Base02_DeployVaultsAndAdapters is Base01_DeployCore {
    // ============================================================
    // PROTOCOL CORE
    // ============================================================

    GiveProtocolCore public protocolCore;

    // ============================================================
    // VAULTS (REAL UUPS PROXIES)
    // ============================================================

    GiveVault4626 public usdcVault;
    GiveVault4626 public daiVault;

    // Vault implementations
    GiveVault4626 public giveVaultImpl;
    CampaignVault4626 public campaignVaultImpl;

    // ============================================================
    // ADAPTERS (REAL CONTRACTS)
    // ============================================================

    MockAavePool public aavePool; // Mock external Aave pool
    AaveAdapter public aaveUsdcAdapter;
    CompoundingAdapter public compoundingDaiAdapter;
    PendleAdapter public pendleUsdcAdapter;
    MockYieldAdapter public mockUsdcAdapter;

    // ============================================================
    // STRATEGY MANAGERS
    // ============================================================

    StrategyManager public usdcVaultManager;
    StrategyManager public daiVaultManager;

    // ============================================================
    // VAULT & ADAPTER IDS
    // ============================================================

    bytes32 public usdcVaultId;
    bytes32 public daiVaultId;
    bytes32 public aaveUsdcAdapterId;
    bytes32 public compoundingDaiAdapterId;
    bytes32 public pendleUsdcAdapterId;
    bytes32 public mockUsdcAdapterId;

    // ============================================================
    // RISK PROFILES
    // ============================================================

    bytes32 public conservativeRiskId;
    bytes32 public moderateRiskId;

    // ============================================================
    // MODULE ROLE IDS
    // ============================================================

    bytes32 public constant VAULT_MODULE_MANAGER_ROLE = keccak256("VAULT_MODULE_MANAGER_ROLE");
    bytes32 public constant ADAPTER_MODULE_MANAGER_ROLE = keccak256("ADAPTER_MODULE_MANAGER_ROLE");
    bytes32 public constant RISK_MODULE_MANAGER_ROLE = keccak256("RISK_MODULE_MANAGER_ROLE");

    // ============================================================
    // SETUP
    // ============================================================

    function setUp() public virtual override {
        super.setUp(); // Deploy core infrastructure from Base01

        // ========================================
        // STEP 1: Deploy GiveProtocolCore
        // ========================================

        GiveProtocolCore protocolImpl = new GiveProtocolCore();
        bytes memory protocolInitData =
            abi.encodeWithSelector(GiveProtocolCore.initialize.selector, address(aclManager));

        ERC1967Proxy protocolProxy = new ERC1967Proxy(address(protocolImpl), protocolInitData);
        protocolCore = GiveProtocolCore(address(protocolProxy));

        emit log_named_address("GiveProtocolCore deployed at", address(protocolCore));

        // ========================================
        // STEP 2: Grant Module Manager Roles
        // ========================================

        vm.startPrank(admin);
        aclManager.createRole(VAULT_MODULE_MANAGER_ROLE, admin);
        aclManager.createRole(ADAPTER_MODULE_MANAGER_ROLE, admin);
        aclManager.createRole(RISK_MODULE_MANAGER_ROLE, admin);

        aclManager.grantRole(VAULT_MODULE_MANAGER_ROLE, protocolAdmin);
        aclManager.grantRole(ADAPTER_MODULE_MANAGER_ROLE, protocolAdmin);
        aclManager.grantRole(RISK_MODULE_MANAGER_ROLE, protocolAdmin);
        vm.stopPrank();

        emit log_string("Module manager roles configured");

        // ========================================
        // STEP 3: Configure Risk Profiles
        // ========================================

        conservativeRiskId = keccak256("risk.conservative");
        moderateRiskId = keccak256("risk.moderate");

        vm.startPrank(protocolAdmin);

        // Conservative profile: 10% LTV, low limits (for future Phase 9)
        protocolCore.configureRisk(
            conservativeRiskId,
            RiskModule.RiskConfigInput({
                id: conservativeRiskId,
                ltvBps: 1000, // 10% - Future Phase 9 synthetic borrowing
                liquidationThresholdBps: 1200, // 12% - Future Phase 9
                liquidationPenaltyBps: 500, // 5% - Future Phase 9
                borrowCapBps: 3000, // 30% (stored but not enforced)
                depositCapBps: 5000, // 50% (stored but not enforced)
                dataHash: bytes32(0), // No additional metadata
                maxDeposit: 1_000_000e6, // $1M max deposit (ENFORCED NOW)
                maxBorrow: 100_000e6 // $100k max borrow (for Phase 9)
            })
        );

        // Moderate profile: 50% LTV, higher limits (for future Phase 9)
        protocolCore.configureRisk(
            moderateRiskId,
            RiskModule.RiskConfigInput({
                id: moderateRiskId,
                ltvBps: 5000, // 50% - Future Phase 9 synthetic borrowing
                liquidationThresholdBps: 6000, // 60% - Future Phase 9
                liquidationPenaltyBps: 1000, // 10% - Future Phase 9
                borrowCapBps: 5000, // 50% (stored but not enforced)
                depositCapBps: 7000, // 70% (stored but not enforced)
                dataHash: bytes32(0), // No additional metadata
                maxDeposit: 10_000_000e6, // $10M max deposit (ENFORCED NOW)
                maxBorrow: 5_000_000e6 // $5M max borrow (for Phase 9)
            })
        );

        vm.stopPrank();

        emit log_string("Risk profiles configured");

        // ========================================
        // STEP 4: Deploy Mock Aave Pool
        // ========================================

        aavePool = new MockAavePool();
        aavePool.initReserve(address(usdc), 6);
        aavePool.initReserve(address(dai), 18);

        emit log_named_address("MockAavePool deployed at", address(aavePool));

        // ========================================
        // STEP 5: Deploy Vault Implementations
        // ========================================

        giveVaultImpl = new GiveVault4626();
        campaignVaultImpl = new CampaignVault4626();

        emit log_named_address("GiveVault4626 implementation at", address(giveVaultImpl));
        emit log_named_address("CampaignVault4626 implementation at", address(campaignVaultImpl));

        // ========================================
        // STEP 6: Deploy USDC Vault
        // ========================================

        usdcVaultId = keccak256("vault.usdc.general");

        bytes memory usdcVaultInitData = abi.encodeWithSelector(
            GiveVault4626.initialize.selector,
            address(usdc), // asset
            "GIVE USDC Vault", // name
            "gvUSDC", // symbol
            admin, // admin
            address(aclManager), // acl
            address(giveVaultImpl) // implementation
        );

        ERC1967Proxy usdcVaultProxy = new ERC1967Proxy(address(giveVaultImpl), usdcVaultInitData);
        usdcVault = GiveVault4626(payable(address(usdcVaultProxy)));

        emit log_named_address("USDC Vault deployed at", address(usdcVault));

        // Grant VAULT_MANAGER_ROLE to protocolCore so it can call syncRiskLimits during assignVaultRisk
        vm.startPrank(admin);
        bytes32 vaultManagerRole = usdcVault.VAULT_MANAGER_ROLE();
        usdcVault.grantRole(vaultManagerRole, address(protocolCore));
        vm.stopPrank();

        // Register USDC vault in protocol core
        vm.prank(protocolAdmin);
        protocolCore.configureVault(
            usdcVaultId,
            VaultModule.VaultConfigInput({
                id: usdcVaultId,
                proxy: address(usdcVault),
                implementation: address(giveVaultImpl),
                asset: address(usdc),
                adapterId: bytes32(0), // Set later
                donationModuleId: bytes32(0),
                riskId: conservativeRiskId,
                cashBufferBps: 1000,
                slippageBps: 100,
                maxLossBps: 50
            })
        );

        // Assign risk profile
        vm.prank(protocolAdmin);
        protocolCore.assignVaultRisk(usdcVaultId, conservativeRiskId);

        // ========================================
        // STEP 7: Deploy DAI Vault
        // ========================================

        daiVaultId = keccak256("vault.dai.general");

        bytes memory daiVaultInitData = abi.encodeWithSelector(
            GiveVault4626.initialize.selector,
            address(dai), // asset
            "GIVE DAI Vault", // name
            "gvDAI", // symbol
            admin, // admin
            address(aclManager), // acl
            address(giveVaultImpl) // implementation
        );

        ERC1967Proxy daiVaultProxy = new ERC1967Proxy(address(giveVaultImpl), daiVaultInitData);
        daiVault = GiveVault4626(payable(address(daiVaultProxy)));

        emit log_named_address("DAI Vault deployed at", address(daiVault));

        // Grant VAULT_MANAGER_ROLE to protocolCore so it can call syncRiskLimits during assignVaultRisk
        vm.startPrank(admin);
        daiVault.grantRole(daiVault.VAULT_MANAGER_ROLE(), address(protocolCore));
        vm.stopPrank();

        // Register DAI vault in protocol core
        vm.prank(protocolAdmin);
        protocolCore.configureVault(
            daiVaultId,
            VaultModule.VaultConfigInput({
                id: daiVaultId,
                proxy: address(daiVault),
                implementation: address(giveVaultImpl),
                asset: address(dai),
                adapterId: bytes32(0), // Set later
                donationModuleId: bytes32(0),
                riskId: moderateRiskId,
                cashBufferBps: 1000,
                slippageBps: 100,
                maxLossBps: 50
            })
        );

        // Assign risk profile
        vm.prank(protocolAdmin);
        protocolCore.assignVaultRisk(daiVaultId, moderateRiskId);

        // ========================================
        // STEP 8: Deploy Adapters
        // ========================================

        // Aave USDC Adapter
        aaveUsdcAdapterId = keccak256("adapter.aave.usdc");
        aaveUsdcAdapter = new AaveAdapter(address(usdc), address(usdcVault), address(aavePool), admin);

        emit log_named_address("Aave USDC Adapter deployed at", address(aaveUsdcAdapter));

        // Register Aave adapter in protocol core
        vm.prank(protocolAdmin);
        protocolCore.configureAdapter(
            aaveUsdcAdapterId,
            AdapterModule.AdapterConfigInput({
                id: aaveUsdcAdapterId,
                proxy: address(aaveUsdcAdapter),
                implementation: address(aaveUsdcAdapter), // Not proxied for now
                asset: address(usdc),
                vault: address(usdcVault),
                kind: GiveTypes.AdapterKind.BalanceGrowth, // Aave aTokens rebase
                metadataHash: keccak256("ipfs://QmAaveAdapter")
            })
        );

        // Compounding DAI Adapter
        compoundingDaiAdapterId = keccak256("adapter.compounding.dai");
        compoundingDaiAdapter = new CompoundingAdapter(compoundingDaiAdapterId, address(dai), address(daiVault));

        emit log_named_address("Compounding DAI Adapter deployed at", address(compoundingDaiAdapter));

        // Register Compounding adapter in protocol core
        vm.prank(protocolAdmin);
        protocolCore.configureAdapter(
            compoundingDaiAdapterId,
            AdapterModule.AdapterConfigInput({
                id: compoundingDaiAdapterId,
                proxy: address(compoundingDaiAdapter),
                implementation: address(compoundingDaiAdapter),
                asset: address(dai),
                vault: address(daiVault),
                kind: GiveTypes.AdapterKind.CompoundingValue, // Exchange rate accrues
                metadataHash: keccak256("ipfs://QmCompoundingAdapter")
            })
        );

        // Mock USDC Adapter (for testing rebalancing)
        mockUsdcAdapterId = keccak256("adapter.mock.usdc");
        mockUsdcAdapter = new MockYieldAdapter(address(usdc), address(usdcVault), admin);

        emit log_named_address("Mock USDC Adapter deployed at", address(mockUsdcAdapter));

        // Register Mock adapter in protocol core
        vm.prank(protocolAdmin);
        protocolCore.configureAdapter(
            mockUsdcAdapterId,
            AdapterModule.AdapterConfigInput({
                id: mockUsdcAdapterId,
                proxy: address(mockUsdcAdapter),
                implementation: address(mockUsdcAdapter),
                asset: address(usdc),
                vault: address(usdcVault),
                kind: GiveTypes.AdapterKind.CompoundingValue,
                metadataHash: keccak256("ipfs://QmMockAdapter")
            })
        );

        // Pendle USDC Adapter (fixed-maturity token flow)
        // In this base fixture, market/PT/router are deterministic placeholders since
        // tests here exercise strategy wiring and adapter approval lifecycle.
        pendleUsdcAdapterId = keccak256("adapter.pendle.usdc");
        pendleUsdcAdapter = new PendleAdapter(
            pendleUsdcAdapterId,
            address(usdc),
            address(usdcVault),
            makeAddr("pendleRouter"),
            makeAddr("pendleMarket"),
            makeAddr("pendlePt")
        );

        emit log_named_address("Pendle USDC Adapter deployed at", address(pendleUsdcAdapter));

        vm.prank(protocolAdmin);
        protocolCore.configureAdapter(
            pendleUsdcAdapterId,
            AdapterModule.AdapterConfigInput({
                id: pendleUsdcAdapterId,
                proxy: address(pendleUsdcAdapter),
                implementation: address(pendleUsdcAdapter),
                asset: address(usdc),
                vault: address(usdcVault),
                kind: GiveTypes.AdapterKind.FixedMaturityToken,
                metadataHash: keccak256("ipfs://QmPendleAdapter")
            })
        );

        // ========================================
        // STEP 9: Deploy StrategyManagers
        // ========================================

        usdcVaultManager = new StrategyManager(
            address(usdcVault), protocolAdmin, address(strategyRegistry), address(campaignRegistry)
        );

        daiVaultManager =
            new StrategyManager(address(daiVault), protocolAdmin, address(strategyRegistry), address(campaignRegistry));

        emit log_named_address("USDC Vault StrategyManager deployed at", address(usdcVaultManager));
        emit log_named_address("DAI Vault StrategyManager deployed at", address(daiVaultManager));

        // Grant StrategyManager roles
        vm.startPrank(protocolAdmin);
        usdcVaultManager.grantRole(usdcVaultManager.STRATEGY_MANAGER_ROLE(), strategyAdmin);
        daiVaultManager.grantRole(daiVaultManager.STRATEGY_MANAGER_ROLE(), strategyAdmin);
        vm.stopPrank();

        // Ensure ACL manager knows about VAULT_MANAGER_ROLE and delegate to managers
        vm.startPrank(admin);
        bytes32 VAULT_MANAGER_ROLE_HASH = usdcVault.VAULT_MANAGER_ROLE();
        if (!aclManager.roleExists(VAULT_MANAGER_ROLE_HASH)) {
            aclManager.createRole(VAULT_MANAGER_ROLE_HASH, admin);
        }
        aclManager.grantRole(VAULT_MANAGER_ROLE_HASH, address(usdcVaultManager));
        aclManager.grantRole(VAULT_MANAGER_ROLE_HASH, address(daiVaultManager));
        aclManager.grantRole(VAULT_MANAGER_ROLE_HASH, strategyAdmin);
        aclManager.grantRole(VAULT_MANAGER_ROLE_HASH, protocolAdmin);
        // Grant VAULT_MANAGER_ROLE to StrategyManager contracts locally so they can call setActiveAdapter()
        usdcVault.grantRole(usdcVault.VAULT_MANAGER_ROLE(), address(usdcVaultManager));
        daiVault.grantRole(daiVault.VAULT_MANAGER_ROLE(), address(daiVaultManager));
        vm.stopPrank();

        // Sanity: confirm managers hold the role locally
        assertTrue(
            usdcVault.hasRole(usdcVault.VAULT_MANAGER_ROLE(), address(usdcVaultManager)),
            "USDC manager missing vault role"
        );
        assertTrue(
            daiVault.hasRole(daiVault.VAULT_MANAGER_ROLE(), address(daiVaultManager)), "DAI manager missing vault role"
        );

        emit log_string("StrategyManagers granted VAULT_MANAGER_ROLE on vaults");

        // ========================================
        // STEP 10: Configure Vault Adapters
        // ========================================

        vm.startPrank(strategyAdmin);

        // Approve adapters for USDC vault
        usdcVaultManager.setAdapterApproval(address(aaveUsdcAdapter), true);
        usdcVaultManager.setAdapterApproval(address(mockUsdcAdapter), true);
        usdcVaultManager.setAdapterApproval(address(pendleUsdcAdapter), true);
        usdcVaultManager.setActiveAdapter(address(aaveUsdcAdapter));

        // Approve adapter for DAI vault
        daiVaultManager.setAdapterApproval(address(compoundingDaiAdapter), true);
        daiVaultManager.setActiveAdapter(address(compoundingDaiAdapter));

        vm.stopPrank();

        emit log_string("Adapters approved and activated");
    }

    // ============================================================
    // VALIDATION HELPERS (INTERNAL TO AVOID AUTO-RUN)
    // ============================================================

    /**
     * @notice Validates GiveProtocolCore deployment
     * @dev Internal to avoid running as standalone test
     */
    function _validateProtocolCore() internal view {
        assertTrue(address(protocolCore) != address(0), "ProtocolCore should be deployed");
        assertEq(address(protocolCore.aclManager()), address(aclManager), "ProtocolCore ACL mismatch");
    }

    /**
     * @notice Validates vault deployments and configurations
     * @dev Internal to avoid running as standalone test
     */
    function _validateVaults() internal view {
        // USDC Vault
        assertTrue(address(usdcVault) != address(0), "USDC Vault should be deployed");
        assertEq(address(usdcVault.asset()), address(usdc), "USDC Vault asset mismatch");
        assertEq(usdcVault.cashBufferBps(), 1000, "USDC Vault cash buffer mismatch");

        // DAI Vault
        assertTrue(address(daiVault) != address(0), "DAI Vault should be deployed");
        assertEq(address(daiVault.asset()), address(dai), "DAI Vault asset mismatch");
        assertEq(daiVault.cashBufferBps(), 1000, "DAI Vault cash buffer mismatch");
    }

    /**
     * @notice Validates adapter deployments and configurations
     * @dev Internal to avoid running as standalone test
     */
    function _validateAdapters() internal view {
        // Aave USDC Adapter
        assertTrue(address(aaveUsdcAdapter) != address(0), "Aave USDC Adapter should be deployed");
        assertEq(address(aaveUsdcAdapter.asset()), address(usdc), "Aave adapter asset mismatch");
        assertEq(aaveUsdcAdapter.vault(), address(usdcVault), "Aave adapter vault mismatch");

        // Compounding DAI Adapter
        assertTrue(address(compoundingDaiAdapter) != address(0), "Compounding DAI Adapter should be deployed");
        assertEq(address(compoundingDaiAdapter.asset()), address(dai), "Compounding adapter asset mismatch");
        assertEq(compoundingDaiAdapter.vault(), address(daiVault), "Compounding adapter vault mismatch");

        // Pendle USDC Adapter
        assertTrue(address(pendleUsdcAdapter) != address(0), "Pendle USDC Adapter should be deployed");
        assertEq(address(pendleUsdcAdapter.asset()), address(usdc), "Pendle adapter asset mismatch");
        assertEq(pendleUsdcAdapter.vault(), address(usdcVault), "Pendle adapter vault mismatch");
    }

    /**
     * @notice Validates StrategyManager deployments
     * @dev Internal to avoid running as standalone test
     */
    function _validateStrategyManagers() internal view {
        // USDC Vault Manager
        assertTrue(address(usdcVaultManager) != address(0), "USDC StrategyManager should be deployed");
        assertEq(address(usdcVaultManager.vault()), address(usdcVault), "USDC StrategyManager vault mismatch");
        assertTrue(
            usdcVaultManager.approvedAdapters(address(aaveUsdcAdapter)),
            "Aave adapter should be approved for USDC vault"
        );
        assertTrue(
            usdcVaultManager.approvedAdapters(address(pendleUsdcAdapter)),
            "Pendle adapter should be approved for USDC vault"
        );
        assertEq(address(usdcVault.activeAdapter()), address(aaveUsdcAdapter), "USDC vault active adapter mismatch");

        // DAI Vault Manager
        assertTrue(address(daiVaultManager) != address(0), "DAI StrategyManager should be deployed");
        assertEq(address(daiVaultManager.vault()), address(daiVault), "DAI StrategyManager vault mismatch");
        assertTrue(
            daiVaultManager.approvedAdapters(address(compoundingDaiAdapter)),
            "Compounding adapter should be approved for DAI vault"
        );
        assertEq(address(daiVault.activeAdapter()), address(compoundingDaiAdapter), "DAI vault active adapter mismatch");
    }
}
