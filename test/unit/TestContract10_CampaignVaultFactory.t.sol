// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {CampaignVaultFactory} from "../../src/factory/CampaignVaultFactory.sol";
import {ACLManager} from "../../src/governance/ACLManager.sol";
import {GiveTypes} from "../../src/types/GiveTypes.sol";

contract MockCampaignVaultImpl {
    bytes32 public vaultId;
    bytes32 public campaignId;
    bytes32 public strategyId;
    bytes32 public lockProfile;

    function initialize(address, string calldata name, string calldata, address, address, address, address) external {
        vaultId = keccak256(bytes(name));
    }

    function initializeCampaign(bytes32 campaignId_, bytes32 strategyId_, bytes32 lockProfile_) external {
        campaignId = campaignId_;
        strategyId = strategyId_;
        lockProfile = lockProfile_;
    }
}

contract MockCampaignRegistryForFactory {
    bytes32 public configuredStrategyId;
    bytes32 public lastCampaignId;
    address public lastVault;
    bytes32 public lastLockProfile;

    function setConfiguredStrategy(bytes32 strategyId_) external {
        configuredStrategyId = strategyId_;
    }

    function getCampaign(bytes32 campaignId_) external view returns (GiveTypes.CampaignConfig memory cfg) {
        uint256[49] memory gap;
        cfg = GiveTypes.CampaignConfig({
            id: campaignId_,
            proposer: address(0),
            curator: address(0),
            payoutRecipient: address(0xCAFE),
            vault: address(0),
            strategyId: configuredStrategyId,
            metadataHash: bytes32(0),
            targetStake: 0,
            minStake: 0,
            totalStaked: 0,
            lockedStake: 0,
            initialDeposit: 0,
            fundraisingStart: 0,
            fundraisingEnd: 0,
            createdAt: 0,
            updatedAt: 0,
            status: GiveTypes.CampaignStatus.Submitted,
            lockProfile: bytes32(0),
            checkpointQuorumBps: 0,
            checkpointVotingDelay: 0,
            checkpointVotingPeriod: 0,
            exists: true,
            payoutsHalted: false,
            __gap: gap
        });
    }

    function setCampaignVault(bytes32 campaignId_, address vault, bytes32 lockProfile_) external {
        lastCampaignId = campaignId_;
        lastVault = vault;
        lastLockProfile = lockProfile_;
    }
}

contract MockStrategyRegistryForFactory {
    bytes32 public lastStrategyId;
    address public lastVault;

    function registerStrategyVault(bytes32 strategyId, address vault) external {
        lastStrategyId = strategyId;
        lastVault = vault;
    }
}

contract MockPayoutRouterForFactory {
    address public lastVault;
    bytes32 public lastCampaignId;
    bool public lastAuthorized;

    function registerCampaignVault(address vault, bytes32 campaignId) external {
        lastVault = vault;
        lastCampaignId = campaignId;
    }

    function setAuthorizedCaller(address vault, bool authorized) external {
        lastVault = vault;
        lastAuthorized = authorized;
    }
}

contract TestContract10_CampaignVaultFactory is Test {
    CampaignVaultFactory public factory;
    ACLManager public acl;
    MockCampaignVaultImpl public vaultImpl;
    MockCampaignRegistryForFactory public campaignRegistry;
    MockStrategyRegistryForFactory public strategyRegistry;
    MockPayoutRouterForFactory public payoutRouter;

    address public admin;
    address public upgrader;
    address public campaignAdmin;

    bytes32 public campaignId;
    bytes32 public strategyId;
    bytes32 public lockProfile;

    function setUp() public {
        admin = makeAddr("admin");
        upgrader = makeAddr("upgrader");
        campaignAdmin = makeAddr("campaignAdmin");

        campaignId = keccak256("campaign");
        strategyId = keccak256("strategy");
        lockProfile = keccak256("lock-profile");

        acl = new ACLManager();
        acl.initialize(admin, upgrader);

        bytes32 campaignAdminRole = acl.campaignAdminRole();
        vm.prank(admin);
        acl.grantRole(campaignAdminRole, campaignAdmin);

        vaultImpl = new MockCampaignVaultImpl();
        campaignRegistry = new MockCampaignRegistryForFactory();
        strategyRegistry = new MockStrategyRegistryForFactory();
        payoutRouter = new MockPayoutRouterForFactory();

        campaignRegistry.setConfiguredStrategy(strategyId);

        factory = new CampaignVaultFactory();
        factory.initialize(address(acl), address(campaignRegistry), address(strategyRegistry), address(payoutRouter), address(vaultImpl));
    }

    function _params() private returns (CampaignVaultFactory.DeployParams memory params) {
        params = CampaignVaultFactory.DeployParams({
            campaignId: campaignId,
            strategyId: strategyId,
            lockProfile: lockProfile,
            asset: makeAddr("asset"),
            admin: campaignAdmin,
            name: "Climate Vault",
            symbol: "gCLIMATE"
        });
    }

    function test_Contract10_Case01_predictVaultAddress_isDeterministic() public {
        CampaignVaultFactory.DeployParams memory params = _params();
        address predicted1 = factory.predictVaultAddress(params);
        address predicted2 = factory.predictVaultAddress(params);
        assertEq(predicted1, predicted2);
        assertTrue(predicted1 != address(0));
    }

    function test_Contract10_Case02_deployCampaignVault_registersEverywhere() public {
        CampaignVaultFactory.DeployParams memory params = _params();

        vm.prank(campaignAdmin);
        address deployed = factory.deployCampaignVault(params);

        assertEq(campaignRegistry.lastCampaignId(), campaignId);
        assertEq(campaignRegistry.lastVault(), deployed);
        assertEq(campaignRegistry.lastLockProfile(), lockProfile);

        assertEq(strategyRegistry.lastStrategyId(), strategyId);
        assertEq(strategyRegistry.lastVault(), deployed);

        assertEq(payoutRouter.lastVault(), deployed);
        assertEq(payoutRouter.lastCampaignId(), campaignId);
        assertTrue(payoutRouter.lastAuthorized());
    }

    function test_Contract10_Case03_duplicateDeployment_reverts() public {
        CampaignVaultFactory.DeployParams memory params = _params();

        vm.startPrank(campaignAdmin);
        factory.deployCampaignVault(params);
        vm.expectRevert();
        factory.deployCampaignVault(params);
        vm.stopPrank();
    }

    function test_Contract10_Case04_strategyMismatch_reverts() public {
        campaignRegistry.setConfiguredStrategy(keccak256("other-strategy"));
        CampaignVaultFactory.DeployParams memory params = _params();

        vm.prank(campaignAdmin);
        vm.expectRevert();
        factory.deployCampaignVault(params);
    }

    function test_Contract10_Case05_setImplementation_requiresCampaignAdminRole() public {
        address newImpl = makeAddr("newImpl");

        vm.prank(makeAddr("unauthorized"));
        vm.expectRevert();
        factory.setVaultImplementation(newImpl);

        vm.prank(campaignAdmin);
        factory.setVaultImplementation(newImpl);
        assertEq(factory.vaultImplementation(), newImpl);
    }
}
