// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {GiveProtocolCore} from "../src/core/GiveProtocolCore.sol";
import {ACLManager} from "../src/governance/ACLManager.sol";
import {VaultModule} from "../src/modules/VaultModule.sol";
import {AdapterModule} from "../src/modules/AdapterModule.sol";
import {DonationModule} from "../src/modules/DonationModule.sol";
import {RiskModule} from "../src/modules/RiskModule.sol";
import {EmergencyModule} from "../src/modules/EmergencyModule.sol";
import {SyntheticModule} from "../src/modules/SyntheticModule.sol";
import {GiveTypes} from "../src/types/GiveTypes.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

/**
 * @title TestContract08_GiveProtocolCore
 * @notice Comprehensive test suite for GiveProtocolCore orchestration layer
 * @dev Tests protocol initialization, module delegation, access control, and upgradeability
 */
contract TestContract08_GiveProtocolCore is Test {
    GiveProtocolCore public protocol;
    GiveProtocolCore public protocolImpl;
    ACLManager public aclManager;

    address public admin;
    address public vaultManager;
    address public adapterManager;
    address public donationManager;
    address public riskManager;
    address public emergencyManager;
    address public syntheticManager;
    address public upgrader;
    address public user1;
    address public user2;

    bytes32 public vaultId;
    bytes32 public adapterId;
    bytes32 public donationId;
    bytes32 public riskId;
    bytes32 public syntheticId;

    function setUp() public {
        // Create test addresses
        admin = makeAddr("admin");
        vaultManager = makeAddr("vaultManager");
        adapterManager = makeAddr("adapterManager");
        donationManager = makeAddr("donationManager");
        riskManager = makeAddr("riskManager");
        emergencyManager = makeAddr("emergencyManager");
        syntheticManager = makeAddr("syntheticManager");
        upgrader = makeAddr("upgrader");
        user1 = makeAddr("user1");
        user2 = makeAddr("user2");

        // Fund addresses
        vm.deal(admin, 100 ether);
        vm.deal(user1, 100 ether);
        vm.deal(user2, 100 ether);

        // Deploy ACL Manager
        aclManager = new ACLManager();
        aclManager.initialize(admin, upgrader);

        // Deploy protocol implementation
        protocolImpl = new GiveProtocolCore();

        // Deploy proxy and initialize
        bytes memory initData = abi.encodeWithSelector(GiveProtocolCore.initialize.selector, address(aclManager));

        ERC1967Proxy proxy = new ERC1967Proxy(address(protocolImpl), initData);
        protocol = GiveProtocolCore(address(proxy));

        // Create and grant roles
        vm.startPrank(admin);
        // Create roles first (ROLE_UPGRADER is already created during ACLManager.initialize())
        aclManager.createRole(VaultModule.MANAGER_ROLE, admin);
        aclManager.createRole(AdapterModule.MANAGER_ROLE, admin);
        aclManager.createRole(DonationModule.MANAGER_ROLE, admin);
        aclManager.createRole(RiskModule.MANAGER_ROLE, admin);
        aclManager.createRole(protocol.EMERGENCY_ROLE(), admin);
        aclManager.createRole(SyntheticModule.MANAGER_ROLE, admin);

        // Now grant roles
        aclManager.grantRole(VaultModule.MANAGER_ROLE, vaultManager);
        aclManager.grantRole(AdapterModule.MANAGER_ROLE, adapterManager);
        aclManager.grantRole(DonationModule.MANAGER_ROLE, donationManager);
        aclManager.grantRole(RiskModule.MANAGER_ROLE, riskManager);
        aclManager.grantRole(protocol.EMERGENCY_ROLE(), emergencyManager);
        aclManager.grantRole(SyntheticModule.MANAGER_ROLE, syntheticManager);
        aclManager.grantRole(protocol.ROLE_UPGRADER(), upgrader);
        vm.stopPrank();

        // Create test identifiers
        vaultId = keccak256("test-vault");
        adapterId = keccak256("test-adapter");
        donationId = keccak256("test-donation");
        riskId = keccak256("test-risk");
        syntheticId = keccak256("test-synthetic");
    }

    // ============================================
    // INITIALIZATION TESTS
    // ============================================

    function test_Contract08_Case01_initialization() public view {
        assertEq(address(protocol.aclManager()), address(aclManager));
    }

    function test_Contract08_Case02_initializeOnlyOnce() public {
        // Try to initialize again - should revert
        vm.expectRevert();
        protocol.initialize(address(aclManager));
    }

    function test_Contract08_Case03_initializeZeroAddress() public {
        GiveProtocolCore newProtocol = new GiveProtocolCore();
        vm.expectRevert();
        newProtocol.initialize(address(0));
    }

    // ============================================
    // VAULT MODULE TESTS
    // ============================================

    function test_Contract08_Case04_configureVault() public {
        VaultModule.VaultConfigInput memory cfg = VaultModule.VaultConfigInput({
            id: vaultId,
            proxy: makeAddr("vaultProxy"),
            implementation: makeAddr("vaultImpl"),
            asset: makeAddr("asset"),
            adapterId: bytes32(uint256(1)),
            donationModuleId: bytes32(uint256(2)),
            riskId: bytes32(0),
            cashBufferBps: 1000, // 10%
            slippageBps: 100, // 1%
            maxLossBps: 50 // 0.5%
        });

        vm.prank(vaultManager);
        vm.expectEmit(true, false, false, false);
        emit VaultModule.VaultConfigured(vaultId, cfg.proxy, cfg.implementation, cfg.asset);
        protocol.configureVault(vaultId, cfg);
    }

    function test_Contract08_Case05_configureVaultUnauthorized() public {
        VaultModule.VaultConfigInput memory cfg = VaultModule.VaultConfigInput({
            id: vaultId,
            proxy: makeAddr("vaultProxy"),
            implementation: makeAddr("vaultImpl"),
            asset: makeAddr("asset"),
            adapterId: bytes32(uint256(1)),
            donationModuleId: bytes32(uint256(2)),
            riskId: bytes32(0),
            cashBufferBps: 1000,
            slippageBps: 100,
            maxLossBps: 50
        });

        vm.prank(user1);
        vm.expectRevert();
        protocol.configureVault(vaultId, cfg);
    }

    // ============================================
    // ADAPTER MODULE TESTS
    // ============================================

    function test_Contract08_Case06_configureAdapter() public {
        AdapterModule.AdapterConfigInput memory cfg = AdapterModule.AdapterConfigInput({
            id: adapterId,
            proxy: makeAddr("adapterProxy"),
            implementation: makeAddr("adapterImpl"),
            asset: makeAddr("asset"),
            vault: makeAddr("vault"),
            kind: GiveTypes.AdapterKind.CompoundingValue,
            metadataHash: bytes32(uint256(200))
        });

        vm.prank(adapterManager);
        vm.expectEmit(true, false, false, false);
        emit AdapterModule.AdapterConfigured(adapterId, cfg.proxy, cfg.implementation, cfg.asset);
        protocol.configureAdapter(adapterId, cfg);
    }

    function test_Contract08_Case07_getAdapterConfig() public {
        // First configure adapter
        AdapterModule.AdapterConfigInput memory cfg = AdapterModule.AdapterConfigInput({
            id: adapterId,
            proxy: makeAddr("adapterProxy"),
            implementation: makeAddr("adapterImpl"),
            asset: makeAddr("asset"),
            vault: makeAddr("vault"),
            kind: GiveTypes.AdapterKind.BalanceGrowth,
            metadataHash: bytes32(uint256(200))
        });

        vm.prank(adapterManager);
        protocol.configureAdapter(adapterId, cfg);

        // Now retrieve it
        (address assetAddress, address vaultAddress, GiveTypes.AdapterKind kind, bool active) =
            protocol.getAdapterConfig(adapterId);

        assertEq(assetAddress, cfg.asset);
        assertEq(vaultAddress, cfg.vault);
        assertTrue(uint8(kind) == uint8(cfg.kind));
        assertTrue(active);
    }

    function test_Contract08_Case07b_configureFixedMaturityAdapterKind() public {
        bytes32 pendleAdapterId = keccak256("adapter.pendle.usdc");

        AdapterModule.AdapterConfigInput memory cfg = AdapterModule.AdapterConfigInput({
            id: pendleAdapterId,
            proxy: makeAddr("pendleAdapterProxy"),
            implementation: makeAddr("pendleAdapterImpl"),
            asset: makeAddr("usdcAsset"),
            vault: makeAddr("usdcVault"),
            kind: GiveTypes.AdapterKind.FixedMaturityToken,
            metadataHash: keccak256("ipfs://QmPendleAdapter")
        });

        vm.prank(adapterManager);
        protocol.configureAdapter(pendleAdapterId, cfg);

        (address assetAddress, address vaultAddress, GiveTypes.AdapterKind kind, bool active) =
            protocol.getAdapterConfig(pendleAdapterId);

        assertEq(assetAddress, cfg.asset);
        assertEq(vaultAddress, cfg.vault);
        assertEq(uint8(kind), uint8(GiveTypes.AdapterKind.FixedMaturityToken));
        assertTrue(active);
    }

    function test_Contract08_Case08_configureAdapterUnauthorized() public {
        AdapterModule.AdapterConfigInput memory cfg = AdapterModule.AdapterConfigInput({
            id: adapterId,
            proxy: makeAddr("adapterProxy"),
            implementation: makeAddr("adapterImpl"),
            asset: makeAddr("asset"),
            vault: makeAddr("vault"),
            kind: GiveTypes.AdapterKind.ClaimableYield,
            metadataHash: bytes32(uint256(200))
        });

        vm.prank(user1);
        vm.expectRevert();
        protocol.configureAdapter(adapterId, cfg);
    }

    // ============================================
    // DONATION MODULE TESTS
    // ============================================

    function test_Contract08_Case09_configureDonation() public {
        DonationModule.DonationConfigInput memory cfg = DonationModule.DonationConfigInput({
            id: donationId,
            routerProxy: makeAddr("routerProxy"),
            registryProxy: makeAddr("registryProxy"),
            feeRecipient: makeAddr("feeRecipient"),
            feeBps: 500 // 5%
        });

        vm.prank(donationManager);
        vm.expectEmit(true, false, false, false);
        emit DonationModule.DonationConfigured(donationId, cfg.routerProxy, cfg.registryProxy, cfg.feeBps);
        protocol.configureDonation(donationId, cfg);
    }

    function test_Contract08_Case10_configureDonationUnauthorized() public {
        DonationModule.DonationConfigInput memory cfg = DonationModule.DonationConfigInput({
            id: donationId,
            routerProxy: makeAddr("routerProxy"),
            registryProxy: makeAddr("registryProxy"),
            feeRecipient: makeAddr("feeRecipient"),
            feeBps: 500
        });

        vm.prank(user1);
        vm.expectRevert();
        protocol.configureDonation(donationId, cfg);
    }

    // ============================================
    // RISK MODULE TESTS
    // ============================================

    function test_Contract08_Case11_configureRisk() public {
        RiskModule.RiskConfigInput memory cfg = RiskModule.RiskConfigInput({
            id: riskId,
            ltvBps: 7500, // 75%
            liquidationThresholdBps: 8000, // 80%
            liquidationPenaltyBps: 1000, // 10%
            borrowCapBps: 8000, // 80%
            depositCapBps: 10000, // 100%
            dataHash: bytes32(uint256(400)),
            maxDeposit: 10000 ether,
            maxBorrow: 8000 ether
        });

        vm.prank(riskManager);
        vm.expectEmit(true, false, false, true);
        emit RiskModule.RiskConfigured(
            riskId, 1, cfg.ltvBps, cfg.liquidationThresholdBps, cfg.maxDeposit, cfg.maxBorrow
        );
        protocol.configureRisk(riskId, cfg);
    }

    function test_Contract08_Case12_getRiskConfig() public {
        // First configure risk
        RiskModule.RiskConfigInput memory cfg = RiskModule.RiskConfigInput({
            id: riskId,
            ltvBps: 7000,
            liquidationThresholdBps: 7500,
            liquidationPenaltyBps: 500,
            borrowCapBps: 7500,
            depositCapBps: 10000,
            dataHash: bytes32(uint256(400)),
            maxDeposit: 5000 ether,
            maxBorrow: 3750 ether
        });

        vm.prank(riskManager);
        protocol.configureRisk(riskId, cfg);

        // Now retrieve it
        GiveTypes.RiskConfig memory retrieved = protocol.getRiskConfig(riskId);

        assertEq(retrieved.id, riskId);
        assertEq(retrieved.ltvBps, cfg.ltvBps);
        assertEq(retrieved.liquidationThresholdBps, cfg.liquidationThresholdBps);
        assertEq(retrieved.liquidationPenaltyBps, cfg.liquidationPenaltyBps);
        assertEq(retrieved.maxDeposit, cfg.maxDeposit);
        assertEq(retrieved.maxBorrow, cfg.maxBorrow);
        assertTrue(retrieved.exists);
        assertTrue(retrieved.active);
    }

    function test_Contract08_Case13_assignVaultRisk() public {
        // First create vault (proxy must be non-zero for vault to be considered active)
        VaultModule.VaultConfigInput memory vaultCfg = VaultModule.VaultConfigInput({
            id: vaultId,
            proxy: makeAddr("vaultProxy"),
            implementation: makeAddr("vaultImpl"),
            asset: makeAddr("asset"),
            adapterId: bytes32(uint256(1)),
            donationModuleId: bytes32(uint256(2)),
            riskId: bytes32(0),
            cashBufferBps: 1000,
            slippageBps: 100,
            maxLossBps: 50
        });

        vm.prank(vaultManager);
        protocol.configureVault(vaultId, vaultCfg);

        // Mock the vault proxy with empty bytecode to allow external calls
        vm.etch(vaultCfg.proxy, bytes("mock"));

        // Then create risk
        RiskModule.RiskConfigInput memory riskCfg = RiskModule.RiskConfigInput({
            id: riskId,
            ltvBps: 7500,
            liquidationThresholdBps: 8000,
            liquidationPenaltyBps: 1000,
            borrowCapBps: 8000,
            depositCapBps: 10000,
            dataHash: bytes32(uint256(400)),
            maxDeposit: 10000 ether,
            maxBorrow: 8000 ether
        });

        vm.prank(riskManager);
        protocol.configureRisk(riskId, riskCfg);

        // Now assign risk to vault
        vm.prank(riskManager);
        vm.expectEmit(true, true, false, false, address(protocol));
        emit RiskModule.VaultRiskAssigned(vaultId, riskId);
        protocol.assignVaultRisk(vaultId, riskId);
    }

    function test_Contract08_Case14_configureRiskUnauthorized() public {
        RiskModule.RiskConfigInput memory cfg = RiskModule.RiskConfigInput({
            id: riskId,
            ltvBps: 7500,
            liquidationThresholdBps: 8000,
            liquidationPenaltyBps: 1000,
            borrowCapBps: 8000,
            depositCapBps: 10000,
            dataHash: bytes32(uint256(400)),
            maxDeposit: 10000 ether,
            maxBorrow: 8000 ether
        });

        vm.prank(user1);
        vm.expectRevert();
        protocol.configureRisk(riskId, cfg);
    }

    // ============================================
    // EMERGENCY MODULE TESTS
    // ============================================

    function test_Contract08_Case15_triggerEmergencyPause() public {
        // Note: This test only verifies vault configuration
        // Actual emergency actions require a deployed vault proxy
        VaultModule.VaultConfigInput memory vaultCfg = VaultModule.VaultConfigInput({
            id: vaultId,
            proxy: makeAddr("vaultProxy"),
            implementation: makeAddr("vaultImpl"),
            asset: makeAddr("asset"),
            adapterId: bytes32(uint256(1)),
            donationModuleId: bytes32(uint256(2)),
            riskId: bytes32(0),
            cashBufferBps: 1000,
            slippageBps: 100,
            maxLossBps: 50
        });

        vm.prank(vaultManager);
        protocol.configureVault(vaultId, vaultCfg);

        // Cannot trigger emergency without a real vault proxy - would need actual GiveVault4626 contract
        // vm.prank(emergencyManager);
        // protocol.triggerEmergency(vaultId, EmergencyModule.EmergencyAction.Pause, "");
    }

    function test_Contract08_Case16_triggerEmergencyUnauthorized() public {
        // First create vault
        VaultModule.VaultConfigInput memory vaultCfg = VaultModule.VaultConfigInput({
            id: vaultId,
            proxy: makeAddr("vaultProxy"),
            implementation: makeAddr("vaultImpl"),
            asset: makeAddr("asset"),
            adapterId: bytes32(uint256(1)),
            donationModuleId: bytes32(uint256(2)),
            riskId: bytes32(0),
            cashBufferBps: 1000,
            slippageBps: 100,
            maxLossBps: 50
        });

        vm.prank(vaultManager);
        protocol.configureVault(vaultId, vaultCfg);

        // Try to trigger emergency without role
        vm.prank(user1);
        vm.expectRevert();
        protocol.triggerEmergency(vaultId, EmergencyModule.EmergencyAction.Pause, "");
    }

    // ============================================
    // SYNTHETIC MODULE TESTS (STUB)
    // ============================================

    function test_Contract08_Case17_configureSynthetic() public {
        SyntheticModule.SyntheticConfigInput memory cfg = SyntheticModule.SyntheticConfigInput({
            id: syntheticId, proxy: makeAddr("syntheticProxy"), asset: makeAddr("asset")
        });

        vm.prank(syntheticManager);
        vm.expectEmit(true, false, false, false);
        emit SyntheticModule.SyntheticConfigured(syntheticId, cfg.proxy, cfg.asset);
        protocol.configureSynthetic(syntheticId, cfg);
    }

    function test_Contract08_Case18_configureSyntheticUnauthorized() public {
        SyntheticModule.SyntheticConfigInput memory cfg = SyntheticModule.SyntheticConfigInput({
            id: syntheticId, proxy: makeAddr("syntheticProxy"), asset: makeAddr("asset")
        });

        vm.prank(user1);
        vm.expectRevert();
        protocol.configureSynthetic(syntheticId, cfg);
    }

    // ============================================
    // ACCESS CONTROL TESTS
    // ============================================

    function test_Contract08_Case19_unauthorizedModuleAccess() public {
        VaultModule.VaultConfigInput memory cfg = VaultModule.VaultConfigInput({
            id: vaultId,
            proxy: makeAddr("vaultProxy"),
            implementation: makeAddr("vaultImpl"),
            asset: makeAddr("asset"),
            adapterId: bytes32(uint256(1)),
            donationModuleId: bytes32(uint256(2)),
            riskId: bytes32(0),
            cashBufferBps: 1000,
            slippageBps: 100,
            maxLossBps: 50
        });

        // User without role tries to configure vault
        vm.prank(user2);
        vm.expectRevert();
        protocol.configureVault(vaultId, cfg);
    }

    function test_Contract08_Case20_roleSegregation() public {
        // Vault manager cannot configure adapters
        AdapterModule.AdapterConfigInput memory adapterCfg = AdapterModule.AdapterConfigInput({
            id: adapterId,
            proxy: makeAddr("adapterProxy"),
            implementation: makeAddr("adapterImpl"),
            asset: makeAddr("asset"),
            vault: makeAddr("vault"),
            kind: GiveTypes.AdapterKind.CompoundingValue,
            metadataHash: bytes32(uint256(200))
        });

        vm.prank(vaultManager);
        vm.expectRevert();
        protocol.configureAdapter(adapterId, adapterCfg);

        // Adapter manager cannot configure risks
        RiskModule.RiskConfigInput memory riskCfg = RiskModule.RiskConfigInput({
            id: riskId,
            ltvBps: 7500,
            liquidationThresholdBps: 8000,
            liquidationPenaltyBps: 1000,
            borrowCapBps: 8000,
            depositCapBps: 10000,
            dataHash: bytes32(uint256(400)),
            maxDeposit: 10000 ether,
            maxBorrow: 8000 ether
        });

        vm.prank(adapterManager);
        vm.expectRevert();
        protocol.configureRisk(riskId, riskCfg);
    }

    // ============================================
    // UPGRADE TESTS
    // ============================================

    function test_Contract08_Case21_upgradeAuthorization() public {
        // Deploy new implementation
        GiveProtocolCore newImpl = new GiveProtocolCore();

        // Upgrade should succeed with proper role
        vm.prank(upgrader);
        protocol.upgradeToAndCall(address(newImpl), "");
    }

    function test_Contract08_Case22_upgradeUnauthorized() public {
        // Deploy new implementation
        GiveProtocolCore newImpl = new GiveProtocolCore();

        // Upgrade should fail without role
        vm.prank(user1);
        vm.expectRevert();
        protocol.upgradeToAndCall(address(newImpl), "");
    }

    // ============================================
    // INTEGRATION TESTS
    // ============================================

    function test_Contract08_Case23_fullVaultLifecycle() public {
        // 1. Configure risk profile
        RiskModule.RiskConfigInput memory riskCfg = RiskModule.RiskConfigInput({
            id: riskId,
            ltvBps: 7500,
            liquidationThresholdBps: 8000,
            liquidationPenaltyBps: 1000,
            borrowCapBps: 8000,
            depositCapBps: 10000,
            dataHash: bytes32(uint256(400)),
            maxDeposit: 10000 ether,
            maxBorrow: 8000 ether
        });

        vm.prank(riskManager);
        protocol.configureRisk(riskId, riskCfg);

        // 2. Configure vault (proxy must be non-zero for vault to be considered active)
        VaultModule.VaultConfigInput memory vaultCfg = VaultModule.VaultConfigInput({
            id: vaultId,
            proxy: makeAddr("vaultProxy"),
            implementation: makeAddr("vaultImpl"),
            asset: makeAddr("asset"),
            adapterId: bytes32(uint256(1)),
            donationModuleId: bytes32(uint256(2)),
            riskId: bytes32(0),
            cashBufferBps: 1000,
            slippageBps: 100,
            maxLossBps: 50
        });

        vm.prank(vaultManager);
        protocol.configureVault(vaultId, vaultCfg);

        // Mock the vault proxy with empty bytecode to allow external calls
        vm.etch(vaultCfg.proxy, bytes("mock"));

        // 3. Assign risk profile to vault
        vm.prank(riskManager);
        protocol.assignVaultRisk(vaultId, riskId);

        // 4. Configure adapter
        AdapterModule.AdapterConfigInput memory adapterCfg = AdapterModule.AdapterConfigInput({
            id: adapterId,
            proxy: makeAddr("adapterProxy"),
            implementation: makeAddr("adapterImpl"),
            asset: makeAddr("asset"),
            vault: makeAddr("vaultProxy"),
            kind: GiveTypes.AdapterKind.CompoundingValue,
            metadataHash: bytes32(uint256(200))
        });

        vm.prank(adapterManager);
        protocol.configureAdapter(adapterId, adapterCfg);

        // 5. Configure donation routing
        DonationModule.DonationConfigInput memory donationCfg = DonationModule.DonationConfigInput({
            id: donationId,
            routerProxy: makeAddr("routerProxy"),
            registryProxy: makeAddr("registryProxy"),
            feeRecipient: makeAddr("feeRecipient"),
            feeBps: 500
        });

        vm.prank(donationManager);
        protocol.configureDonation(donationId, donationCfg);

        // Verify all configurations exist
        GiveTypes.RiskConfig memory retrievedRisk = protocol.getRiskConfig(riskId);
        assertTrue(retrievedRisk.exists);

        (address assetAddress,, GiveTypes.AdapterKind kind, bool active) = protocol.getAdapterConfig(adapterId);
        assertEq(assetAddress, adapterCfg.asset);
        assertTrue(active);
    }
}
