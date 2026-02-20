// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";

import {StorageLib} from "../../src/storage/StorageLib.sol";
import {GiveTypes} from "../../src/types/GiveTypes.sol";

contract StorageLibHarness {
    function setInitialized(bool value) external {
        StorageLib.system().initialized = value;
    }

    function ensureInitializedExternal() external view {
        StorageLib.ensureInitialized();
    }

    function setVault(bytes32 vaultId, bool active) external {
        GiveTypes.VaultConfig storage cfg = StorageLib.vault(vaultId);
        cfg.proxy = address(this);
        cfg.active = active;
    }

    function ensureVaultActiveExternal(bytes32 vaultId) external view {
        StorageLib.ensureVaultActive(vaultId);
    }

    function setAdapter(bytes32 adapterId, bool active) external {
        GiveTypes.AdapterConfig storage cfg = StorageLib.adapter(adapterId);
        cfg.proxy = address(this);
        cfg.active = active;
    }

    function ensureAdapterActiveExternal(bytes32 adapterId) external view {
        StorageLib.ensureAdapterActive(adapterId);
    }

    function setRisk(bytes32 riskId, bool exists) external {
        GiveTypes.RiskConfig storage cfg = StorageLib.riskConfig(riskId);
        cfg.exists = exists;
    }

    function ensureRiskExternal(bytes32 riskId) external view {
        StorageLib.ensureRiskConfig(riskId);
    }

    function setStrategy(bytes32 strategyId, bool exists) external {
        GiveTypes.StrategyConfig storage cfg = StorageLib.strategy(strategyId);
        cfg.exists = exists;
    }

    function ensureStrategyExternal(bytes32 strategyId) external view {
        StorageLib.ensureStrategy(strategyId);
    }

    function setCampaign(bytes32 campaignId, bool exists) external {
        GiveTypes.CampaignConfig storage cfg = StorageLib.campaign(campaignId);
        cfg.exists = exists;
    }

    function ensureCampaignExternal(bytes32 campaignId) external view {
        StorageLib.ensureCampaign(campaignId);
    }

    function setCampaignVault(bytes32 vaultId, bool exists) external {
        GiveTypes.CampaignVaultMeta storage meta = StorageLib.campaignVaultMeta(vaultId);
        meta.exists = exists;
    }

    function ensureCampaignVaultExternal(bytes32 vaultId) external view {
        StorageLib.ensureCampaignVault(vaultId);
    }

    function setRole(bytes32 roleId, bool exists) external {
        GiveTypes.RoleAssignments storage assignment = StorageLib.role(roleId);
        assignment.exists = exists;
    }

    function ensureRoleExternal(bytes32 roleId) external view {
        StorageLib.ensureRole(roleId);
    }

    function setAddressExternal(bytes32 key, address value) external {
        StorageLib.setAddress(key, value);
    }

    function getAddressExternal(bytes32 key) external view returns (address) {
        return StorageLib.getAddress(key);
    }

    function setUintExternal(bytes32 key, uint256 value) external {
        StorageLib.setUint(key, value);
    }

    function getUintExternal(bytes32 key) external view returns (uint256) {
        return StorageLib.getUint(key);
    }

    function setBoolExternal(bytes32 key, bool value) external {
        StorageLib.setBool(key, value);
    }

    function getBoolExternal(bytes32 key) external view returns (bool) {
        return StorageLib.getBool(key);
    }

    function setBytes32External(bytes32 key, bytes32 value) external {
        StorageLib.setBytes32(key, value);
    }

    function getBytes32External(bytes32 key) external view returns (bytes32) {
        return StorageLib.getBytes32(key);
    }

    function setVaultCampaignExternal(address vaultAddress, bytes32 campaignId) external {
        StorageLib.setVaultCampaign(vaultAddress, campaignId);
    }

    function getVaultCampaignExternal(address vaultAddress) external view returns (bytes32) {
        return StorageLib.getVaultCampaign(vaultAddress);
    }
}

contract TestContract20_StorageLib is Test {
    StorageLibHarness public harness;

    function setUp() public {
        harness = new StorageLibHarness();
    }

    function test_Contract20_Case01_ensureInitialized_revertsWhenFalse() public {
        harness.setInitialized(false);

        vm.expectRevert(StorageLib.StorageNotInitialized.selector);
        harness.ensureInitializedExternal();
    }

    function test_Contract20_Case02_ensureInitialized_passesWhenTrue() public {
        harness.setInitialized(true);
        harness.ensureInitializedExternal();
    }

    function test_Contract20_Case03_ensureVaultActive_revertAndPass() public {
        bytes32 vaultId = keccak256("vault");

        vm.expectRevert(abi.encodeWithSelector(StorageLib.InvalidVault.selector, vaultId));
        harness.ensureVaultActiveExternal(vaultId);

        harness.setVault(vaultId, false);
        vm.expectRevert(abi.encodeWithSelector(StorageLib.InvalidVault.selector, vaultId));
        harness.ensureVaultActiveExternal(vaultId);

        harness.setVault(vaultId, true);
        harness.ensureVaultActiveExternal(vaultId);
    }

    function test_Contract20_Case04_ensureAdapterActive_revertAndPass() public {
        bytes32 adapterId = keccak256("adapter");

        vm.expectRevert(abi.encodeWithSelector(StorageLib.InvalidAdapter.selector, adapterId));
        harness.ensureAdapterActiveExternal(adapterId);

        harness.setAdapter(adapterId, false);
        vm.expectRevert(abi.encodeWithSelector(StorageLib.InvalidAdapter.selector, adapterId));
        harness.ensureAdapterActiveExternal(adapterId);

        harness.setAdapter(adapterId, true);
        harness.ensureAdapterActiveExternal(adapterId);
    }

    function test_Contract20_Case05_ensureRisk_revertAndPass() public {
        bytes32 riskId = keccak256("risk");

        vm.expectRevert(abi.encodeWithSelector(StorageLib.InvalidRisk.selector, riskId));
        harness.ensureRiskExternal(riskId);

        harness.setRisk(riskId, true);
        harness.ensureRiskExternal(riskId);
    }

    function test_Contract20_Case06_ensureStrategy_revertAndPass() public {
        bytes32 strategyId = keccak256("strategy");

        vm.expectRevert(abi.encodeWithSelector(StorageLib.InvalidStrategy.selector, strategyId));
        harness.ensureStrategyExternal(strategyId);

        harness.setStrategy(strategyId, true);
        harness.ensureStrategyExternal(strategyId);
    }

    function test_Contract20_Case07_ensureCampaign_revertAndPass() public {
        bytes32 campaignId = keccak256("campaign");

        vm.expectRevert(abi.encodeWithSelector(StorageLib.InvalidCampaign.selector, campaignId));
        harness.ensureCampaignExternal(campaignId);

        harness.setCampaign(campaignId, true);
        harness.ensureCampaignExternal(campaignId);
    }

    function test_Contract20_Case08_ensureCampaignVault_revertAndPass() public {
        bytes32 vaultId = keccak256("campaign-vault");

        vm.expectRevert(abi.encodeWithSelector(StorageLib.InvalidCampaignVault.selector, vaultId));
        harness.ensureCampaignVaultExternal(vaultId);

        harness.setCampaignVault(vaultId, true);
        harness.ensureCampaignVaultExternal(vaultId);
    }

    function test_Contract20_Case09_ensureRole_revertAndPass() public {
        bytes32 roleId = keccak256("role");

        vm.expectRevert(abi.encodeWithSelector(StorageLib.InvalidRole.selector, roleId));
        harness.ensureRoleExternal(roleId);

        harness.setRole(roleId, true);
        harness.ensureRoleExternal(roleId);
    }

    function test_Contract20_Case10_registryAddressRoundTrip() public {
        bytes32 key = keccak256("key-address");
        address value = makeAddr("value");

        harness.setAddressExternal(key, value);
        assertEq(harness.getAddressExternal(key), value);
    }

    function test_Contract20_Case11_registryScalarRoundTrip() public {
        bytes32 keyUint = keccak256("key-uint");
        bytes32 keyBool = keccak256("key-bool");
        bytes32 keyBytes = keccak256("key-bytes");

        harness.setUintExternal(keyUint, 123456);
        harness.setBoolExternal(keyBool, true);
        harness.setBytes32External(keyBytes, keccak256("value-bytes"));

        assertEq(harness.getUintExternal(keyUint), 123456);
        assertTrue(harness.getBoolExternal(keyBool));
        assertEq(harness.getBytes32External(keyBytes), keccak256("value-bytes"));
    }

    function test_Contract20_Case12_vaultCampaignLookupRoundTrip() public {
        address vaultAddress = makeAddr("vault-address");
        bytes32 campaignId = keccak256("lookup-campaign");

        harness.setVaultCampaignExternal(vaultAddress, campaignId);
        assertEq(harness.getVaultCampaignExternal(vaultAddress), campaignId);
    }
}
