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
}
