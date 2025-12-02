// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test, console} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {CampaignRegistry} from "../src/registry/CampaignRegistry.sol";
import {StrategyRegistry} from "../src/registry/StrategyRegistry.sol";
import {ACLManager} from "../src/governance/ACLManager.sol";
import {GiveTypes} from "../src/types/GiveTypes.sol";

/**
 * @title   TestContract03_CampaignRegistry
 * @author  GIVE Labs
 * @notice  Comprehensive test suite for CampaignRegistry contract
 * @dev     Tests campaign lifecycle, H-01 deposit refund/slash fix, stake management,
 *          checkpoint governance, and access control.
 */
contract TestContract03_CampaignRegistry is Test {
    CampaignRegistry public campaignRegistry;
    CampaignRegistry public implementation;
    StrategyRegistry public strategyRegistry;
    ACLManager public aclManager;
    ERC1967Proxy public proxy;

    address public superAdmin;
    address public campaignAdmin;
    address public strategyAdmin;
    address public curator;
    address public checkpointCouncil;
    address public upgrader;
    address public proposer;
    address public ngo;
    address public supporter1;
    address public supporter2;
    address public user1;

    bytes32 public constant ROLE_SUPER_ADMIN = keccak256("ROLE_SUPER_ADMIN");
    bytes32 public constant ROLE_UPGRADER = keccak256("ROLE_UPGRADER");
    bytes32 public constant ROLE_CAMPAIGN_ADMIN = keccak256("ROLE_CAMPAIGN_ADMIN");
    bytes32 public constant ROLE_STRATEGY_ADMIN = keccak256("ROLE_STRATEGY_ADMIN");
    bytes32 public constant ROLE_CAMPAIGN_CURATOR = keccak256("ROLE_CAMPAIGN_CURATOR");
    bytes32 public constant ROLE_CHECKPOINT_COUNCIL = keccak256("ROLE_CHECKPOINT_COUNCIL");

    bytes32 public constant CAMPAIGN_ID_1 = keccak256("CAMPAIGN_SAVE_RAINFOREST");
    bytes32 public constant CAMPAIGN_ID_2 = keccak256("CAMPAIGN_CLEAN_OCEAN");
    bytes32 public constant STRATEGY_ID = keccak256("STRATEGY_AAVE_USDC");
    bytes32 public constant METADATA_HASH = keccak256("ipfs://Qm...");
    bytes32 public constant RISK_LOW = keccak256("LOW");
    bytes32 public constant LOCK_PROFILE = keccak256("STANDARD_LOCK");

    string public constant METADATA_CID = "QmTest123";
    uint256 public constant MIN_DEPOSIT = 0.005 ether;

    address public adapter;
    address public vault;

    // Events
    event CampaignSubmitted(
        bytes32 indexed id, address indexed proposer, bytes32 metadataHash, string metadataCID, uint256 depositAmount
    );
    event CampaignApproved(bytes32 indexed id, address indexed curator);
    event CampaignRejected(bytes32 indexed id, string reason);
    event CampaignStatusChanged(
        bytes32 indexed id, GiveTypes.CampaignStatus previousStatus, GiveTypes.CampaignStatus newStatus
    );
    event DepositRefunded(bytes32 indexed id, address indexed recipient, uint256 amount);
    event DepositSlashed(bytes32 indexed id, uint256 amount);
    event PayoutRecipientUpdated(bytes32 indexed id, address indexed previousRecipient, address indexed newRecipient);
    event StakeDeposited(bytes32 indexed id, address indexed supporter, uint256 amount, uint256 totalStaked);
    event StakeExitRequested(bytes32 indexed id, address indexed supporter, uint256 amountRequested);
    event StakeExitFinalized(
        bytes32 indexed id, address indexed supporter, uint256 amountWithdrawn, uint256 remainingStake
    );
    event LockedStakeUpdated(bytes32 indexed id, uint256 previousAmount, uint256 newAmount);
    event CampaignVaultRegistered(bytes32 indexed campaignId, address indexed vault, bytes32 lockProfile);
    event CheckpointScheduled(bytes32 indexed campaignId, uint256 index, uint64 start, uint64 end, uint16 quorumBps);
    event CheckpointStatusUpdated(
        bytes32 indexed campaignId,
        uint256 index,
        GiveTypes.CheckpointStatus previousStatus,
        GiveTypes.CheckpointStatus newStatus
    );
    event CheckpointVoteCast(
        bytes32 indexed campaignId, uint256 index, address indexed supporter, bool support, uint208 weight
    );
    event PayoutsHalted(bytes32 indexed campaignId, bool halted);

    function setUp() public {
        superAdmin = address(this);
        campaignAdmin = address(0x1);
        strategyAdmin = address(0x2);
        curator = address(0x3);
        checkpointCouncil = address(0x4);
        upgrader = address(0x5);
        proposer = address(0x10);
        ngo = address(0x11);
        supporter1 = address(0x20);
        supporter2 = address(0x21);
        user1 = address(0x30);

        adapter = address(0x100);
        vault = address(0x200);

        // Fund accounts
        vm.deal(proposer, 10 ether);
        vm.deal(user1, 10 ether);

        // Deploy ACLManager
        ACLManager aclImpl = new ACLManager();
        bytes memory aclInitData = abi.encodeWithSelector(ACLManager.initialize.selector, superAdmin, upgrader);
        ERC1967Proxy aclProxy = new ERC1967Proxy(address(aclImpl), aclInitData);
        aclManager = ACLManager(address(aclProxy));

        // Grant roles
        aclManager.grantRole(ROLE_CAMPAIGN_ADMIN, campaignAdmin);
        aclManager.grantRole(ROLE_STRATEGY_ADMIN, strategyAdmin);
        aclManager.grantRole(ROLE_CAMPAIGN_CURATOR, curator);
        aclManager.grantRole(ROLE_CHECKPOINT_COUNCIL, checkpointCouncil);

        // Deploy StrategyRegistry
        StrategyRegistry stratImpl = new StrategyRegistry();
        bytes memory stratInitData = abi.encodeWithSelector(StrategyRegistry.initialize.selector, address(aclManager));
        ERC1967Proxy stratProxy = new ERC1967Proxy(address(stratImpl), stratInitData);
        strategyRegistry = StrategyRegistry(address(stratProxy));

        // Register a strategy
        vm.prank(strategyAdmin);
        strategyRegistry.registerStrategy(
            StrategyRegistry.StrategyInput({
                id: STRATEGY_ID, adapter: adapter, riskTier: RISK_LOW, maxTvl: 1_000_000e6, metadataHash: METADATA_HASH
            })
        );

        // Deploy CampaignRegistry
        implementation = new CampaignRegistry();
        bytes memory initData = abi.encodeWithSelector(
            CampaignRegistry.initialize.selector, address(aclManager), address(strategyRegistry)
        );
        proxy = new ERC1967Proxy(address(implementation), initData);
        campaignRegistry = CampaignRegistry(address(proxy));

        console.log("CampaignRegistry proxy deployed at:", address(campaignRegistry));
        console.log("Campaign admin:", campaignAdmin);
        console.log("Proposer:", proposer);
    }

    // ============================================
    // INITIALIZATION TESTS
    // ============================================

    /**
     * @dev Test initial deployment state
     */
    function test_Contract03_Case01_initializationState() public view {
        assertEq(address(campaignRegistry.aclManager()), address(aclManager), "ACL manager should be set");
        assertEq(
            address(campaignRegistry.strategyRegistry()), address(strategyRegistry), "Strategy registry should be set"
        );

        bytes32[] memory ids = campaignRegistry.listCampaignIds();
        assertEq(ids.length, 0, "Should have no campaigns initially");
    }

    /**
     * @dev Test cannot initialize with zero addresses
     */
    function test_Contract03_Case02_cannotInitializeWithZeroAddress() public {
        CampaignRegistry newImpl = new CampaignRegistry();

        // Zero ACL
        bytes memory initData1 =
            abi.encodeWithSelector(CampaignRegistry.initialize.selector, address(0), address(strategyRegistry));
        vm.expectRevert(abi.encodeWithSelector(CampaignRegistry.ZeroAddress.selector));
        new ERC1967Proxy(address(newImpl), initData1);

        // Zero strategy registry
        bytes memory initData2 =
            abi.encodeWithSelector(CampaignRegistry.initialize.selector, address(aclManager), address(0));
        vm.expectRevert(abi.encodeWithSelector(CampaignRegistry.ZeroAddress.selector));
        new ERC1967Proxy(address(newImpl), initData2);
    }

    // ============================================
    // CAMPAIGN SUBMISSION TESTS
    // ============================================

    /**
     * @dev Test successful campaign submission
     */
    function test_Contract03_Case03_submitCampaignSucceeds() public {
        vm.prank(proposer);
        vm.expectEmit(true, true, false, true);
        emit CampaignSubmitted(CAMPAIGN_ID_1, proposer, METADATA_HASH, METADATA_CID, MIN_DEPOSIT);

        campaignRegistry.submitCampaign{value: MIN_DEPOSIT}(
            CampaignRegistry.CampaignInput({
                id: CAMPAIGN_ID_1,
                payoutRecipient: ngo,
                strategyId: STRATEGY_ID,
                metadataHash: METADATA_HASH,
                metadataCID: METADATA_CID,
                targetStake: 100_000e6,
                minStake: 10_000e6,
                fundraisingStart: uint64(block.timestamp),
                fundraisingEnd: uint64(block.timestamp + 30 days)
            })
        );

        GiveTypes.CampaignConfig memory cfg = campaignRegistry.getCampaign(CAMPAIGN_ID_1);
        assertEq(cfg.proposer, proposer, "Proposer should be set");
        assertEq(cfg.payoutRecipient, ngo, "Payout recipient should be set");
        assertEq(cfg.initialDeposit, MIN_DEPOSIT, "Deposit should be stored");
        assertEq(uint256(cfg.status), uint256(GiveTypes.CampaignStatus.Submitted), "Should be in Submitted status");
        assertTrue(cfg.exists, "Campaign should exist");
    }

    /**
     * @dev Test cannot submit campaign with insufficient deposit
     */
    function test_Contract03_Case04_cannotSubmitWithInsufficientDeposit() public {
        vm.prank(proposer);
        vm.expectRevert(
            abi.encodeWithSelector(
                CampaignRegistry.InsufficientSubmissionDeposit.selector, MIN_DEPOSIT, MIN_DEPOSIT - 1
            )
        );
        campaignRegistry.submitCampaign{value: MIN_DEPOSIT - 1}(
            CampaignRegistry.CampaignInput({
                id: CAMPAIGN_ID_1,
                payoutRecipient: ngo,
                strategyId: STRATEGY_ID,
                metadataHash: METADATA_HASH,
                metadataCID: METADATA_CID,
                targetStake: 100_000e6,
                minStake: 10_000e6,
                fundraisingStart: uint64(block.timestamp),
                fundraisingEnd: uint64(block.timestamp + 30 days)
            })
        );
    }

    /**
     * @dev Test cannot submit duplicate campaign
     */
    function test_Contract03_Case05_cannotSubmitDuplicateCampaign() public {
        vm.startPrank(proposer);
        campaignRegistry.submitCampaign{value: MIN_DEPOSIT}(
            CampaignRegistry.CampaignInput({
                id: CAMPAIGN_ID_1,
                payoutRecipient: ngo,
                strategyId: STRATEGY_ID,
                metadataHash: METADATA_HASH,
                metadataCID: METADATA_CID,
                targetStake: 100_000e6,
                minStake: 10_000e6,
                fundraisingStart: uint64(block.timestamp),
                fundraisingEnd: uint64(block.timestamp + 30 days)
            })
        );

        vm.expectRevert(abi.encodeWithSelector(CampaignRegistry.CampaignAlreadyExists.selector, CAMPAIGN_ID_1));
        campaignRegistry.submitCampaign{value: MIN_DEPOSIT}(
            CampaignRegistry.CampaignInput({
                id: CAMPAIGN_ID_1,
                payoutRecipient: ngo,
                strategyId: STRATEGY_ID,
                metadataHash: METADATA_HASH,
                metadataCID: METADATA_CID,
                targetStake: 100_000e6,
                minStake: 10_000e6,
                fundraisingStart: uint64(block.timestamp),
                fundraisingEnd: uint64(block.timestamp + 30 days)
            })
        );
        vm.stopPrank();
    }

    // ============================================
    // H-01 FIX: APPROVAL WITH DEPOSIT REFUND TESTS
    // ============================================

    /**
     * @dev Test campaign approval refunds deposit to proposer (H-01 fix)
     */
    function test_Contract03_Case06_approveCampaignRefundsDeposit() public {
        // Submit campaign
        vm.prank(proposer);
        campaignRegistry.submitCampaign{value: MIN_DEPOSIT}(
            CampaignRegistry.CampaignInput({
                id: CAMPAIGN_ID_1,
                payoutRecipient: ngo,
                strategyId: STRATEGY_ID,
                metadataHash: METADATA_HASH,
                metadataCID: METADATA_CID,
                targetStake: 100_000e6,
                minStake: 10_000e6,
                fundraisingStart: uint64(block.timestamp),
                fundraisingEnd: uint64(block.timestamp + 30 days)
            })
        );

        uint256 proposerBalanceBefore = proposer.balance;

        // Approve campaign (should refund deposit)
        vm.prank(campaignAdmin);
        vm.expectEmit(true, true, false, true);
        emit DepositRefunded(CAMPAIGN_ID_1, proposer, MIN_DEPOSIT);
        vm.expectEmit(true, true, false, false);
        emit CampaignApproved(CAMPAIGN_ID_1, curator);
        campaignRegistry.approveCampaign(CAMPAIGN_ID_1, curator);

        uint256 proposerBalanceAfter = proposer.balance;

        assertEq(proposerBalanceAfter - proposerBalanceBefore, MIN_DEPOSIT, "Deposit should be refunded");

        GiveTypes.CampaignConfig memory cfg = campaignRegistry.getCampaign(CAMPAIGN_ID_1);
        assertEq(cfg.initialDeposit, 0, "Deposit should be zeroed out");
        assertEq(uint256(cfg.status), uint256(GiveTypes.CampaignStatus.Approved), "Should be approved");
        assertEq(cfg.curator, curator, "Curator should be set");
    }

    // ============================================
    // H-01 FIX: REJECTION WITH DEPOSIT SLASH TESTS
    // ============================================

    /**
     * @dev Test campaign rejection slashes deposit (H-01 fix)
     */
    function test_Contract03_Case07_rejectCampaignSlashesDeposit() public {
        // Submit campaign
        vm.prank(proposer);
        campaignRegistry.submitCampaign{value: MIN_DEPOSIT}(
            CampaignRegistry.CampaignInput({
                id: CAMPAIGN_ID_1,
                payoutRecipient: ngo,
                strategyId: STRATEGY_ID,
                metadataHash: METADATA_HASH,
                metadataCID: METADATA_CID,
                targetStake: 100_000e6,
                minStake: 10_000e6,
                fundraisingStart: uint64(block.timestamp),
                fundraisingEnd: uint64(block.timestamp + 30 days)
            })
        );

        uint256 proposerBalanceBefore = proposer.balance;
        uint256 contractBalanceBefore = address(campaignRegistry).balance;

        // Reject campaign (should slash deposit)
        vm.prank(campaignAdmin);
        vm.expectEmit(true, false, false, true);
        emit DepositSlashed(CAMPAIGN_ID_1, MIN_DEPOSIT);
        vm.expectEmit(true, false, false, true);
        emit CampaignRejected(CAMPAIGN_ID_1, "Spam campaign");
        campaignRegistry.rejectCampaign(CAMPAIGN_ID_1, "Spam campaign");

        uint256 proposerBalanceAfter = proposer.balance;
        uint256 contractBalanceAfter = address(campaignRegistry).balance;

        assertEq(proposerBalanceAfter, proposerBalanceBefore, "Proposer balance should not change");
        assertEq(contractBalanceAfter, contractBalanceBefore, "Contract keeps slashed deposit");

        GiveTypes.CampaignConfig memory cfg = campaignRegistry.getCampaign(CAMPAIGN_ID_1);
        assertEq(cfg.initialDeposit, 0, "Deposit should be marked as slashed");
        assertEq(uint256(cfg.status), uint256(GiveTypes.CampaignStatus.Rejected), "Should be rejected");
    }

    /**
     * @dev Test cannot approve non-submitted campaign
     */
    function test_Contract03_Case08_cannotApproveNonSubmittedCampaign() public {
        vm.prank(proposer);
        campaignRegistry.submitCampaign{value: MIN_DEPOSIT}(
            CampaignRegistry.CampaignInput({
                id: CAMPAIGN_ID_1,
                payoutRecipient: ngo,
                strategyId: STRATEGY_ID,
                metadataHash: METADATA_HASH,
                metadataCID: METADATA_CID,
                targetStake: 100_000e6,
                minStake: 10_000e6,
                fundraisingStart: uint64(block.timestamp),
                fundraisingEnd: uint64(block.timestamp + 30 days)
            })
        );

        // Approve first
        vm.prank(campaignAdmin);
        campaignRegistry.approveCampaign(CAMPAIGN_ID_1, curator);

        // Try to approve again
        vm.prank(campaignAdmin);
        vm.expectRevert(
            abi.encodeWithSelector(
                CampaignRegistry.InvalidCampaignStatus.selector, CAMPAIGN_ID_1, GiveTypes.CampaignStatus.Approved
            )
        );
        campaignRegistry.approveCampaign(CAMPAIGN_ID_1, curator);
    }

    /**
     * @dev Test cannot reject already approved campaign
     */
    function test_Contract03_Case09_cannotRejectApprovedCampaign() public {
        vm.prank(proposer);
        campaignRegistry.submitCampaign{value: MIN_DEPOSIT}(
            CampaignRegistry.CampaignInput({
                id: CAMPAIGN_ID_1,
                payoutRecipient: ngo,
                strategyId: STRATEGY_ID,
                metadataHash: METADATA_HASH,
                metadataCID: METADATA_CID,
                targetStake: 100_000e6,
                minStake: 10_000e6,
                fundraisingStart: uint64(block.timestamp),
                fundraisingEnd: uint64(block.timestamp + 30 days)
            })
        );

        // Approve first
        vm.prank(campaignAdmin);
        campaignRegistry.approveCampaign(CAMPAIGN_ID_1, curator);

        // Try to reject
        vm.prank(campaignAdmin);
        vm.expectRevert(
            abi.encodeWithSelector(
                CampaignRegistry.InvalidCampaignStatus.selector, CAMPAIGN_ID_1, GiveTypes.CampaignStatus.Approved
            )
        );
        campaignRegistry.rejectCampaign(CAMPAIGN_ID_1, "Too late");
    }

    /**
     * @dev Test unauthorized user cannot approve campaign
     */
    function test_Contract03_Case10_unauthorizedCannotApproveCampaign() public {
        vm.prank(proposer);
        campaignRegistry.submitCampaign{value: MIN_DEPOSIT}(
            CampaignRegistry.CampaignInput({
                id: CAMPAIGN_ID_1,
                payoutRecipient: ngo,
                strategyId: STRATEGY_ID,
                metadataHash: METADATA_HASH,
                metadataCID: METADATA_CID,
                targetStake: 100_000e6,
                minStake: 10_000e6,
                fundraisingStart: uint64(block.timestamp),
                fundraisingEnd: uint64(block.timestamp + 30 days)
            })
        );

        vm.prank(user1);
        vm.expectRevert(abi.encodeWithSelector(CampaignRegistry.Unauthorized.selector, ROLE_CAMPAIGN_ADMIN, user1));
        campaignRegistry.approveCampaign(CAMPAIGN_ID_1, curator);
    }

    /**
     * @dev Test unauthorized user cannot reject campaign
     */
    function test_Contract03_Case11_unauthorizedCannotRejectCampaign() public {
        vm.prank(proposer);
        campaignRegistry.submitCampaign{value: MIN_DEPOSIT}(
            CampaignRegistry.CampaignInput({
                id: CAMPAIGN_ID_1,
                payoutRecipient: ngo,
                strategyId: STRATEGY_ID,
                metadataHash: METADATA_HASH,
                metadataCID: METADATA_CID,
                targetStake: 100_000e6,
                minStake: 10_000e6,
                fundraisingStart: uint64(block.timestamp),
                fundraisingEnd: uint64(block.timestamp + 30 days)
            })
        );

        vm.prank(user1);
        vm.expectRevert(abi.encodeWithSelector(CampaignRegistry.Unauthorized.selector, ROLE_CAMPAIGN_ADMIN, user1));
        campaignRegistry.rejectCampaign(CAMPAIGN_ID_1, "Unauthorized");
    }

    // ============================================
    // CAMPAIGN STATUS MANAGEMENT TESTS
    // ============================================

    /**
     * @dev Test setCampaignStatus succeeds
     */
    function test_Contract03_Case12_setCampaignStatusSucceeds() public {
        _submitAndApproveCampaign(CAMPAIGN_ID_1);

        vm.prank(campaignAdmin);
        vm.expectEmit(true, false, false, true);
        emit CampaignStatusChanged(CAMPAIGN_ID_1, GiveTypes.CampaignStatus.Approved, GiveTypes.CampaignStatus.Active);
        campaignRegistry.setCampaignStatus(CAMPAIGN_ID_1, GiveTypes.CampaignStatus.Active);

        GiveTypes.CampaignConfig memory cfg = campaignRegistry.getCampaign(CAMPAIGN_ID_1);
        assertEq(uint256(cfg.status), uint256(GiveTypes.CampaignStatus.Active), "Status should be Active");
    }

    /**
     * @dev Test cannot set status to Unknown
     */
    function test_Contract03_Case13_cannotSetStatusToUnknown() public {
        _submitAndApproveCampaign(CAMPAIGN_ID_1);

        vm.prank(campaignAdmin);
        vm.expectRevert(
            abi.encodeWithSelector(
                CampaignRegistry.InvalidCampaignStatus.selector, CAMPAIGN_ID_1, GiveTypes.CampaignStatus.Unknown
            )
        );
        campaignRegistry.setCampaignStatus(CAMPAIGN_ID_1, GiveTypes.CampaignStatus.Unknown);
    }

    // ============================================
    // VIEW FUNCTION TESTS
    // ============================================

    /**
     * @dev Test getCampaign returns correct data
     */
    function test_Contract03_Case14_getCampaignReturnsCorrectData() public {
        _submitAndApproveCampaign(CAMPAIGN_ID_1);

        GiveTypes.CampaignConfig memory cfg = campaignRegistry.getCampaign(CAMPAIGN_ID_1);
        assertEq(cfg.id, CAMPAIGN_ID_1, "ID should match");
        assertEq(cfg.proposer, proposer, "Proposer should match");
        assertEq(cfg.payoutRecipient, ngo, "Recipient should match");
        assertEq(cfg.curator, curator, "Curator should match");
    }

    /**
     * @dev Test listCampaignIds returns all campaigns
     */
    function test_Contract03_Case15_listCampaignIdsWorks() public {
        _submitAndApproveCampaign(CAMPAIGN_ID_1);
        _submitCampaign(CAMPAIGN_ID_2);

        bytes32[] memory ids = campaignRegistry.listCampaignIds();
        assertEq(ids.length, 2, "Should have 2 campaigns");
        assertEq(ids[0], CAMPAIGN_ID_1, "First campaign ID should match");
        assertEq(ids[1], CAMPAIGN_ID_2, "Second campaign ID should match");
    }

    // ============================================
    // UUPS UPGRADE TESTS
    // ============================================

    /**
     * @dev Test only upgrader can upgrade contract
     */
    function test_Contract03_Case16_onlyUpgraderCanUpgrade() public {
        CampaignRegistry newImpl = new CampaignRegistry();

        vm.prank(user1);
        vm.expectRevert(abi.encodeWithSelector(CampaignRegistry.Unauthorized.selector, ROLE_UPGRADER, user1));
        campaignRegistry.upgradeToAndCall(address(newImpl), "");

        vm.prank(upgrader);
        campaignRegistry.upgradeToAndCall(address(newImpl), "");
    }

    // ============================================
    // HELPER FUNCTIONS
    // ============================================

    function _submitCampaign(bytes32 campaignId) private {
        vm.prank(proposer);
        campaignRegistry.submitCampaign{value: MIN_DEPOSIT}(
            CampaignRegistry.CampaignInput({
                id: campaignId,
                payoutRecipient: ngo,
                strategyId: STRATEGY_ID,
                metadataHash: METADATA_HASH,
                metadataCID: METADATA_CID,
                targetStake: 100_000e6,
                minStake: 10_000e6,
                fundraisingStart: uint64(block.timestamp),
                fundraisingEnd: uint64(block.timestamp + 30 days)
            })
        );
    }

    function _submitAndApproveCampaign(bytes32 campaignId) private {
        _submitCampaign(campaignId);
        vm.prank(campaignAdmin);
        campaignRegistry.approveCampaign(campaignId, curator);
    }
}
