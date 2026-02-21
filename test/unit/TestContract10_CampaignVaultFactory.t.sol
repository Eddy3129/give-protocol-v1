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
    address public donationRouter;

    function initialize(address, string calldata name, string calldata, address, address, address, address) external {
        vaultId = keccak256(bytes(name));
    }

    function initializeCampaign(bytes32 campaignId_, bytes32 strategyId_, bytes32 lockProfile_) external {
        campaignId = campaignId_;
        strategyId = strategyId_;
        lockProfile = lockProfile_;

        (bool success, bytes memory data) = msg.sender.staticcall(abi.encodeWithSignature("payoutRouter()"));
        if (success) {
            donationRouter = abi.decode(data, (address));
        }
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

    function setCampaignVault(bytes32 campaignId_, address vault, bytes32 lockProfile_) public virtual {
        lastCampaignId = campaignId_;
        lastVault = vault;
        lastLockProfile = lockProfile_;
    }
}

contract MockStrategyRegistryForFactory {
    bytes32 public lastStrategyId;
    address public lastVault;

    function registerStrategyVault(bytes32 strategyId, address vault) public virtual {
        lastStrategyId = strategyId;
        lastVault = vault;
    }
}

contract MockPayoutRouterForFactory {
    address public lastVault;
    bytes32 public lastCampaignId;
    bool public lastAuthorized;

    function registerCampaignVault(address vault, bytes32 campaignId) public virtual {
        lastVault = vault;
        lastCampaignId = campaignId;
    }

    function setAuthorizedCaller(address vault, bool authorized) public virtual {
        lastVault = vault;
        lastAuthorized = authorized;
    }
}

contract MockCampaignVaultImplWithFail {
    bool public failInitializeCampaign;

    function setFailInitializeCampaign(bool fail) external {
        failInitializeCampaign = fail;
    }

    function initialize(address, string calldata, string calldata, address, address, address, address) external {}

    function initializeCampaign(bytes32, bytes32, bytes32) external view {
        require(!failInitializeCampaign, "init-campaign-fail");
    }
}

contract MockCampaignVaultImplInitCampaignAlwaysFail {
    function initialize(address, string calldata, string calldata, address, address, address, address) external {}

    function initializeCampaign(bytes32, bytes32, bytes32) external pure {
        revert("init-campaign-fail");
    }
}

contract MockCampaignRegistryForFactoryWithFail is MockCampaignRegistryForFactory {
    bool public failSetCampaignVault;

    function setFailSetCampaignVault(bool fail) external {
        failSetCampaignVault = fail;
    }

    function setCampaignVault(bytes32 campaignId_, address vault, bytes32 lockProfile_) public override {
        require(!failSetCampaignVault, "set-campaign-vault-fail");
        super.setCampaignVault(campaignId_, vault, lockProfile_);
    }
}

contract MockStrategyRegistryForFactoryWithFail is MockStrategyRegistryForFactory {
    bool public failRegisterStrategyVault;

    function setFailRegisterStrategyVault(bool fail) external {
        failRegisterStrategyVault = fail;
    }

    function registerStrategyVault(bytes32 strategyId, address vault) public override {
        require(!failRegisterStrategyVault, "register-strategy-vault-fail");
        super.registerStrategyVault(strategyId, vault);
    }
}

contract MockPayoutRouterForFactoryWithFail is MockPayoutRouterForFactory {
    bool public failRegisterCampaignVault;
    bool public failSetAuthorizedCaller;

    function setFailRegisterCampaignVault(bool fail) external {
        failRegisterCampaignVault = fail;
    }

    function setFailSetAuthorizedCaller(bool fail) external {
        failSetAuthorizedCaller = fail;
    }

    function registerCampaignVault(address vault, bytes32 campaignId) public override {
        require(!failRegisterCampaignVault, "register-campaign-vault-fail");
        super.registerCampaignVault(vault, campaignId);
    }

    function setAuthorizedCaller(address vault, bool authorized) public override {
        require(!failSetAuthorizedCaller, "set-authorized-caller-fail");
        super.setAuthorizedCaller(vault, authorized);
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
        factory.initialize(
            address(acl),
            address(campaignRegistry),
            address(strategyRegistry),
            address(payoutRouter),
            address(vaultImpl)
        );
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

        assertEq(MockCampaignVaultImpl(deployed).donationRouter(), address(payoutRouter));
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

    function test_Contract10_Case06_initialize_zeroAddressReverts() public {
        CampaignVaultFactory newFactory = new CampaignVaultFactory();

        vm.expectRevert(CampaignVaultFactory.ZeroAddress.selector);
        newFactory.initialize(
            address(0), address(campaignRegistry), address(strategyRegistry), address(payoutRouter), address(vaultImpl)
        );

        vm.expectRevert(CampaignVaultFactory.ZeroAddress.selector);
        newFactory.initialize(
            address(acl), address(0), address(strategyRegistry), address(payoutRouter), address(vaultImpl)
        );
    }

    function test_Contract10_Case07_setImplementation_zeroAddressReverts() public {
        vm.prank(campaignAdmin);
        vm.expectRevert(CampaignVaultFactory.ZeroAddress.selector);
        factory.setVaultImplementation(address(0));
    }

    function test_Contract10_Case08_deploy_revertsWhenInitializeCampaignFails() public {
        MockCampaignVaultImplInitCampaignAlwaysFail localImpl = new MockCampaignVaultImplInitCampaignAlwaysFail();

        CampaignVaultFactory localFactory = new CampaignVaultFactory();
        localFactory.initialize(
            address(acl),
            address(campaignRegistry),
            address(strategyRegistry),
            address(payoutRouter),
            address(localImpl)
        );

        CampaignVaultFactory.DeployParams memory params = _params();
        vm.prank(campaignAdmin);
        vm.expectRevert(CampaignVaultFactory.InvalidParameters.selector);
        localFactory.deployCampaignVault(params);
    }

    function test_Contract10_Case09_deploy_revertsWhenSetCampaignVaultFails() public {
        MockCampaignRegistryForFactoryWithFail localCampaignRegistry = new MockCampaignRegistryForFactoryWithFail();
        localCampaignRegistry.setConfiguredStrategy(strategyId);
        localCampaignRegistry.setFailSetCampaignVault(true);

        CampaignVaultFactory localFactory = new CampaignVaultFactory();
        localFactory.initialize(
            address(acl),
            address(localCampaignRegistry),
            address(strategyRegistry),
            address(payoutRouter),
            address(vaultImpl)
        );

        CampaignVaultFactory.DeployParams memory params = _params();
        vm.prank(campaignAdmin);
        vm.expectRevert(CampaignVaultFactory.InvalidParameters.selector);
        localFactory.deployCampaignVault(params);
    }

    function test_Contract10_Case10_deploy_revertsWhenRegisterStrategyVaultFails() public {
        MockStrategyRegistryForFactoryWithFail localStrategyRegistry = new MockStrategyRegistryForFactoryWithFail();
        localStrategyRegistry.setFailRegisterStrategyVault(true);

        CampaignVaultFactory localFactory = new CampaignVaultFactory();
        localFactory.initialize(
            address(acl),
            address(campaignRegistry),
            address(localStrategyRegistry),
            address(payoutRouter),
            address(vaultImpl)
        );

        CampaignVaultFactory.DeployParams memory params = _params();
        vm.prank(campaignAdmin);
        vm.expectRevert(CampaignVaultFactory.InvalidParameters.selector);
        localFactory.deployCampaignVault(params);
    }

    function test_Contract10_Case11_deploy_revertsWhenRegisterCampaignVaultFails() public {
        MockPayoutRouterForFactoryWithFail localPayoutRouter = new MockPayoutRouterForFactoryWithFail();
        localPayoutRouter.setFailRegisterCampaignVault(true);

        CampaignVaultFactory localFactory = new CampaignVaultFactory();
        localFactory.initialize(
            address(acl),
            address(campaignRegistry),
            address(strategyRegistry),
            address(localPayoutRouter),
            address(vaultImpl)
        );

        CampaignVaultFactory.DeployParams memory params = _params();
        vm.prank(campaignAdmin);
        vm.expectRevert(CampaignVaultFactory.InvalidParameters.selector);
        localFactory.deployCampaignVault(params);
    }

    function test_Contract10_Case12_deploy_revertsWhenSetAuthorizedCallerFails() public {
        MockPayoutRouterForFactoryWithFail localPayoutRouter = new MockPayoutRouterForFactoryWithFail();
        localPayoutRouter.setFailSetAuthorizedCaller(true);

        CampaignVaultFactory localFactory = new CampaignVaultFactory();
        localFactory.initialize(
            address(acl),
            address(campaignRegistry),
            address(strategyRegistry),
            address(localPayoutRouter),
            address(vaultImpl)
        );

        CampaignVaultFactory.DeployParams memory params = _params();
        vm.prank(campaignAdmin);
        vm.expectRevert(CampaignVaultFactory.InvalidParameters.selector);
        localFactory.deployCampaignVault(params);
    }
}
