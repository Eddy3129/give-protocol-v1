// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {GiveProtocolCore} from "../../src/core/GiveProtocolCore.sol";
import {ACLManager} from "../../src/governance/ACLManager.sol";
import {VaultModule} from "../../src/modules/VaultModule.sol";
import {AdapterModule} from "../../src/modules/AdapterModule.sol";
import {RiskModule} from "../../src/modules/RiskModule.sol";
import {EmergencyModule} from "../../src/modules/EmergencyModule.sol";
import {GiveTypes} from "../../src/types/GiveTypes.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

contract MockVaultForModules {
    bool public emergencyPaused;
    address public adapter;
    bytes32 public syncedRiskId;
    uint256 public syncedMaxDeposit;
    uint256 public syncedMaxBorrow;

    constructor(address adapter_) {
        adapter = adapter_;
    }

    function syncRiskLimits(bytes32 riskId, uint256 maxDeposit, uint256 maxBorrow) external {
        syncedRiskId = riskId;
        syncedMaxDeposit = maxDeposit;
        syncedMaxBorrow = maxBorrow;
    }

    function emergencyPause() external {
        emergencyPaused = true;
    }

    function resumeFromEmergency() external {
        emergencyPaused = false;
    }

    function activeAdapter() external view returns (address) {
        return adapter;
    }

    function emergencyWithdrawFromAdapter() external pure returns (uint256) {
        return 123;
    }

    function forceClearAdapter() external {
        adapter = address(0);
    }
}

contract TestContract12_ModuleLibraries is Test {
    GiveProtocolCore public core;
    ACLManager public acl;
    MockVaultForModules public mockVault;

    address public admin;
    address public upgrader;
    address public vaultManager;
    address public adapterManager;
    address public riskManager;
    address public emergencyManager;

    bytes32 public vaultId;
    bytes32 public adapterId;
    bytes32 public riskId;

    function setUp() public {
        admin = makeAddr("admin");
        upgrader = makeAddr("upgrader");
        vaultManager = makeAddr("vaultManager");
        adapterManager = makeAddr("adapterManager");
        riskManager = makeAddr("riskManager");
        emergencyManager = makeAddr("emergencyManager");

        vaultId = keccak256("vault-id");
        adapterId = keccak256("adapter-id");
        riskId = keccak256("risk-id");

        acl = new ACLManager();
        acl.initialize(admin, upgrader);

        GiveProtocolCore impl = new GiveProtocolCore();
        bytes memory initData = abi.encodeWithSelector(GiveProtocolCore.initialize.selector, address(acl));
        core = GiveProtocolCore(address(new ERC1967Proxy(address(impl), initData)));

        vm.startPrank(admin);
        acl.createRole(VaultModule.MANAGER_ROLE, admin);
        acl.createRole(AdapterModule.MANAGER_ROLE, admin);
        acl.createRole(RiskModule.MANAGER_ROLE, admin);
        acl.createRole(core.EMERGENCY_ROLE(), admin);

        acl.grantRole(VaultModule.MANAGER_ROLE, vaultManager);
        acl.grantRole(AdapterModule.MANAGER_ROLE, adapterManager);
        acl.grantRole(RiskModule.MANAGER_ROLE, riskManager);
        acl.grantRole(core.EMERGENCY_ROLE(), emergencyManager);
        vm.stopPrank();

        mockVault = new MockVaultForModules(makeAddr("adapter"));
    }

    function _configureVault() private {
        VaultModule.VaultConfigInput memory vaultCfg = VaultModule.VaultConfigInput({
            id: vaultId,
            proxy: address(mockVault),
            implementation: makeAddr("vaultImpl"),
            asset: makeAddr("asset"),
            adapterId: adapterId,
            donationModuleId: bytes32(uint256(1)),
            riskId: bytes32(0),
            cashBufferBps: 500,
            slippageBps: 100,
            maxLossBps: 50
        });

        vm.prank(vaultManager);
        core.configureVault(vaultId, vaultCfg);
    }

    function _configureRisk() private {
        RiskModule.RiskConfigInput memory riskCfg = RiskModule.RiskConfigInput({
            id: riskId,
            ltvBps: 7000,
            liquidationThresholdBps: 8000,
            liquidationPenaltyBps: 500,
            borrowCapBps: 7000,
            depositCapBps: 10000,
            dataHash: bytes32(uint256(1)),
            maxDeposit: 1_000_000e6,
            maxBorrow: 700_000e6
        });

        vm.prank(riskManager);
        core.configureRisk(riskId, riskCfg);
    }

    function _validRiskConfig() private view returns (RiskModule.RiskConfigInput memory cfg) {
        cfg = RiskModule.RiskConfigInput({
            id: riskId,
            ltvBps: 7000,
            liquidationThresholdBps: 8000,
            liquidationPenaltyBps: 500,
            borrowCapBps: 7000,
            depositCapBps: 10000,
            dataHash: bytes32(uint256(1)),
            maxDeposit: 1_000_000e6,
            maxBorrow: 700_000e6
        });
    }

    function test_Contract12_Case01_vaultAndAdapterConfig_pathsWork() public {
        _configureVault();

        AdapterModule.AdapterConfigInput memory adapterCfg = AdapterModule.AdapterConfigInput({
            id: adapterId,
            proxy: makeAddr("adapterProxy"),
            implementation: makeAddr("adapterImpl"),
            asset: makeAddr("asset"),
            vault: address(mockVault),
            kind: GiveTypes.AdapterKind.CompoundingValue,
            metadataHash: bytes32(uint256(2))
        });

        vm.prank(adapterManager);
        core.configureAdapter(adapterId, adapterCfg);

        (address assetAddress, address vaultAddress, GiveTypes.AdapterKind kind, bool active) =
            core.getAdapterConfig(adapterId);

        assertEq(assetAddress, adapterCfg.asset);
        assertEq(vaultAddress, adapterCfg.vault);
        assertEq(uint8(kind), uint8(adapterCfg.kind));
        assertTrue(active);
    }

    function test_Contract12_Case02_riskAssign_syncsLimitsToVault() public {
        _configureVault();
        _configureRisk();

        vm.prank(riskManager);
        core.assignVaultRisk(vaultId, riskId);

        assertEq(mockVault.syncedRiskId(), riskId);
        assertEq(mockVault.syncedMaxDeposit(), 1_000_000e6);
        assertEq(mockVault.syncedMaxBorrow(), 700_000e6);
    }

    function test_Contract12_Case03_emergencyPauseUnpauseAndWithdraw() public {
        _configureVault();

        vm.prank(emergencyManager);
        core.triggerEmergency(vaultId, EmergencyModule.EmergencyAction.Pause, bytes(""));
        assertTrue(mockVault.emergencyPaused());

        EmergencyModule.EmergencyWithdrawParams memory params =
            EmergencyModule.EmergencyWithdrawParams({clearAdapter: true});
        vm.prank(emergencyManager);
        core.triggerEmergency(vaultId, EmergencyModule.EmergencyAction.Withdraw, abi.encode(params));

        assertEq(mockVault.adapter(), address(0));

        vm.prank(emergencyManager);
        core.triggerEmergency(vaultId, EmergencyModule.EmergencyAction.Unpause, bytes(""));
        assertFalse(mockVault.emergencyPaused());
    }

    function test_Contract12_Case04_accessControl_enforced() public {
        VaultModule.VaultConfigInput memory vaultCfg = VaultModule.VaultConfigInput({
            id: vaultId,
            proxy: address(mockVault),
            implementation: makeAddr("vaultImpl"),
            asset: makeAddr("asset"),
            adapterId: adapterId,
            donationModuleId: bytes32(uint256(1)),
            riskId: bytes32(0),
            cashBufferBps: 500,
            slippageBps: 100,
            maxLossBps: 50
        });

        vm.prank(makeAddr("unauthorized"));
        vm.expectRevert();
        core.configureVault(vaultId, vaultCfg);

        vm.prank(makeAddr("unauthorized"));
        vm.expectRevert();
        core.triggerEmergency(vaultId, EmergencyModule.EmergencyAction.Pause, bytes(""));
    }

    // ============================================
    // Branch Gap Coverage — RiskModule (Update J)
    // ============================================

    function test_Contract12_Case05_riskModule_assignRiskSyncsMaxDeposit() public {
        _configureVault();

        // Configure risk with a specific maxDeposit
        uint256 maxDeposit = 1_000_000e6;
        RiskModule.RiskConfigInput memory cfg = RiskModule.RiskConfigInput({
            id: riskId,
            ltvBps: 5000,
            liquidationThresholdBps: 6000,
            liquidationPenaltyBps: 500,
            borrowCapBps: 5000,
            depositCapBps: 7000,
            dataHash: bytes32(0),
            maxDeposit: maxDeposit,
            maxBorrow: maxDeposit / 2
        });

        vm.prank(riskManager);
        core.configureRisk(riskId, cfg);

        vm.prank(riskManager);
        core.assignVaultRisk(vaultId, riskId);

        // Verify the limits were synced to the mock vault
        assertEq(mockVault.syncedMaxDeposit(), maxDeposit, "maxDeposit should be synced");
        assertEq(mockVault.syncedMaxBorrow(), maxDeposit / 2, "maxBorrow should be synced");
        assertEq(mockVault.syncedRiskId(), riskId, "riskId should be synced");
    }

    function test_Contract12_Case06_riskModule_configureRiskValidatesParams() public {
        // maxBorrow > maxDeposit should revert with InvalidRiskParameters
        RiskModule.RiskConfigInput memory cfg = RiskModule.RiskConfigInput({
            id: riskId,
            ltvBps: 5000,
            liquidationThresholdBps: 6000,
            liquidationPenaltyBps: 500,
            borrowCapBps: 5000,
            depositCapBps: 7000,
            dataHash: bytes32(0),
            maxDeposit: 1000e6,
            maxBorrow: 2000e6 // borrow > deposit → invalid
        });

        vm.prank(riskManager);
        vm.expectRevert();
        core.configureRisk(riskId, cfg);
    }

    // ============================================
    // Branch Gap Coverage — EmergencyModule (Update J)
    // ============================================

    function test_Contract12_Case07_emergencyModule_pauseResumeCycle() public {
        _configureVault();

        // Pause
        vm.prank(emergencyManager);
        core.triggerEmergency(vaultId, EmergencyModule.EmergencyAction.Pause, bytes(""));
        assertTrue(mockVault.emergencyPaused(), "should be paused");

        // Unpause
        vm.prank(emergencyManager);
        core.triggerEmergency(vaultId, EmergencyModule.EmergencyAction.Unpause, bytes(""));
        assertFalse(mockVault.emergencyPaused(), "should be unpaused");
    }

    function test_Contract12_Case08_emergencyModule_withdrawClearsAdapter() public {
        _configureVault();

        // Pause first (required to withdraw)
        vm.prank(emergencyManager);
        core.triggerEmergency(vaultId, EmergencyModule.EmergencyAction.Pause, bytes(""));

        // Withdraw with clearAdapter=true
        EmergencyModule.EmergencyWithdrawParams memory params =
            EmergencyModule.EmergencyWithdrawParams({clearAdapter: true});

        vm.prank(emergencyManager);
        core.triggerEmergency(vaultId, EmergencyModule.EmergencyAction.Withdraw, abi.encode(params));

        assertEq(mockVault.adapter(), address(0), "adapter should be cleared");
    }

    function test_Contract12_Case09_riskModule_invalidThresholdReverts() public {
        RiskModule.RiskConfigInput memory cfg = _validRiskConfig();
        cfg.liquidationThresholdBps = 10_001;

        vm.prank(riskManager);
        vm.expectRevert();
        core.configureRisk(riskId, cfg);
    }

    function test_Contract12_Case10_riskModule_ltvAboveThresholdReverts() public {
        RiskModule.RiskConfigInput memory cfg = _validRiskConfig();
        cfg.ltvBps = 8001;
        cfg.liquidationThresholdBps = 8000;

        vm.prank(riskManager);
        vm.expectRevert();
        core.configureRisk(riskId, cfg);
    }

    function test_Contract12_Case11_riskModule_invalidPenaltyReverts() public {
        RiskModule.RiskConfigInput memory cfg = _validRiskConfig();
        cfg.liquidationPenaltyBps = 5001;

        vm.prank(riskManager);
        vm.expectRevert();
        core.configureRisk(riskId, cfg);
    }

    function test_Contract12_Case12_riskModule_invalidCapsReverts() public {
        RiskModule.RiskConfigInput memory cfg = _validRiskConfig();
        cfg.depositCapBps = 10_001;

        vm.prank(riskManager);
        vm.expectRevert();
        core.configureRisk(riskId, cfg);
    }

    function test_Contract12_Case13_riskModule_borrowCapAboveDepositCapReverts() public {
        RiskModule.RiskConfigInput memory cfg = _validRiskConfig();
        cfg.depositCapBps = 6000;
        cfg.borrowCapBps = 7000;

        vm.prank(riskManager);
        vm.expectRevert();
        core.configureRisk(riskId, cfg);
    }

    function test_Contract12_Case14_riskModule_idMismatchReverts() public {
        RiskModule.RiskConfigInput memory cfg = _validRiskConfig();
        cfg.id = keccak256("different-risk-id");

        vm.prank(riskManager);
        vm.expectRevert();
        core.configureRisk(riskId, cfg);
    }

    function test_Contract12_Case15_riskModule_boundaryValuesPass() public {
        RiskModule.RiskConfigInput memory cfg = _validRiskConfig();
        cfg.ltvBps = 10_000;
        cfg.liquidationThresholdBps = 10_000;
        cfg.liquidationPenaltyBps = 5_000;
        cfg.depositCapBps = 10_000;
        cfg.borrowCapBps = 10_000;
        cfg.maxBorrow = cfg.maxDeposit;

        vm.prank(riskManager);
        core.configureRisk(riskId, cfg);

        GiveTypes.RiskConfig memory stored = core.getRiskConfig(riskId);
        assertEq(stored.ltvBps, 10_000);
        assertEq(stored.liquidationThresholdBps, 10_000);
        assertEq(stored.liquidationPenaltyBps, 5_000);
        assertEq(stored.depositCapBps, 10_000);
        assertEq(stored.borrowCapBps, 10_000);
        assertEq(stored.maxBorrow, stored.maxDeposit);
    }
}
