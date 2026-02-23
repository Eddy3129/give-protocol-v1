// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";

import {CampaignRegistry} from "../../src/registry/CampaignRegistry.sol";
import {StrategyRegistry} from "../../src/registry/StrategyRegistry.sol";
import {NGORegistry} from "../../src/donation/NGORegistry.sol";
import {ACLManager} from "../../src/governance/ACLManager.sol";
import {GiveTypes} from "../../src/types/GiveTypes.sol";

contract TestContract19_CampaignRegistryBranches is Test {
    ACLManager public aclManager;
    StrategyRegistry public strategyRegistry;
    CampaignRegistry public campaignRegistry;
    NGORegistry public ngoRegistry;

    address public admin;
    address public strategyAdmin;
    address public campaignAdmin;
    address public campaignCurator;
    address public checkpointCouncil;
    address public proposer;
    address public supporter1;
    address public supporter2;

    bytes32 public strategyId;
    bytes32 public campaignId;

    receive() external payable {}

    function setUp() public {
        admin = makeAddr("admin");
        strategyAdmin = makeAddr("strategyAdmin");
        campaignAdmin = makeAddr("campaignAdmin");
        campaignCurator = makeAddr("campaignCurator");
        checkpointCouncil = makeAddr("checkpointCouncil");
        proposer = address(this);
        supporter1 = makeAddr("supporter1");
        supporter2 = makeAddr("supporter2");

        strategyId = keccak256("unit-strategy");
        campaignId = keccak256("unit-campaign");

        vm.deal(proposer, 10 ether);

        aclManager = new ACLManager();
        aclManager.initialize(admin, admin);

        vm.startPrank(admin);
        aclManager.grantRole(aclManager.strategyAdminRole(), strategyAdmin);
        aclManager.grantRole(aclManager.campaignAdminRole(), campaignAdmin);
        aclManager.grantRole(aclManager.campaignCuratorRole(), campaignCurator);
        aclManager.grantRole(aclManager.checkpointCouncilRole(), checkpointCouncil);
        vm.stopPrank();

        strategyRegistry = new StrategyRegistry();
        strategyRegistry.initialize(address(aclManager));

        campaignRegistry = new CampaignRegistry();
        campaignRegistry.initialize(address(aclManager), address(strategyRegistry));

        ngoRegistry = new NGORegistry();
        ngoRegistry.initialize(address(aclManager));

        vm.startPrank(admin);
        aclManager.createRole(ngoRegistry.NGO_MANAGER_ROLE(), admin);
        aclManager.grantRole(ngoRegistry.NGO_MANAGER_ROLE(), campaignAdmin);
        vm.stopPrank();

        vm.prank(campaignAdmin);
        campaignRegistry.setNGORegistry(address(ngoRegistry));

        address ngo = makeAddr("ngo");
        vm.prank(campaignAdmin);
        ngoRegistry.addNGO(ngo, "ipfs://ngo-branch", keccak256("kyc-branch"), campaignAdmin);

        vm.prank(ngo);
        ngoRegistry.setCampaignSubmitter(proposer, true);

        vm.prank(strategyAdmin);
        strategyRegistry.registerStrategy(
            StrategyRegistry.StrategyInput({
                id: strategyId,
                adapter: makeAddr("adapter"),
                riskTier: keccak256("LOW"),
                maxTvl: 1_000_000e6,
                metadataHash: keccak256("strategy-metadata")
            })
        );

        _submitAndApprove();
    }

    function _submitAndApprove() private {
        vm.prank(proposer);
        campaignRegistry.submitCampaign{value: campaignRegistry.MIN_SUBMISSION_DEPOSIT()}(
            CampaignRegistry.CampaignInput({
                id: campaignId,
                payoutRecipient: makeAddr("ngo"),
                strategyId: strategyId,
                metadataHash: keccak256("campaign-metadata"),
                metadataCID: "QmCampaign",
                targetStake: 100_000e6,
                minStake: 1_000e6,
                fundraisingStart: uint64(block.timestamp),
                fundraisingEnd: uint64(block.timestamp + 30 days)
            })
        );

        vm.prank(campaignAdmin);
        campaignRegistry.approveCampaign(campaignId, campaignCurator);
    }

    function _scheduleCheckpoint(uint64 start, uint64 end, uint16 quorumBps) private returns (uint256 index) {
        vm.prank(campaignAdmin);
        index = campaignRegistry.scheduleCheckpoint(
            campaignId,
            CampaignRegistry.CheckpointInput({
                windowStart: start, windowEnd: end, executionDeadline: end + 1, quorumBps: quorumBps
            })
        );
    }

    function _stakeFor(address supporter, uint256 amount) private {
        vm.prank(campaignCurator);
        campaignRegistry.recordStakeDeposit(campaignId, supporter, amount);
    }

    function test_Contract19_Case01_recordStakeDeposit_and_exitFlow() public {
        _stakeFor(supporter1, 1_000e6);

        GiveTypes.SupporterStake memory stake = campaignRegistry.getStakePosition(campaignId, supporter1);
        assertEq(stake.shares, 1_000e6);
        assertTrue(stake.exists);

        vm.prank(campaignCurator);
        campaignRegistry.requestStakeExit(campaignId, supporter1, 400e6);

        stake = campaignRegistry.getStakePosition(campaignId, supporter1);
        assertEq(stake.shares, 600e6);
        assertEq(stake.pendingWithdrawal, 400e6);
        assertTrue(stake.requestedExit);

        vm.prank(campaignAdmin);
        campaignRegistry.finalizeStakeExit(campaignId, supporter1, 400e6);

        stake = campaignRegistry.getStakePosition(campaignId, supporter1);
        assertEq(stake.pendingWithdrawal, 0);
        assertFalse(stake.requestedExit);
        assertEq(stake.shares, 600e6);
    }

    function test_Contract19_Case02_requestStakeExit_missingStakeReverts() public {
        vm.prank(campaignCurator);
        vm.expectRevert(abi.encodeWithSelector(CampaignRegistry.SupporterStakeMissing.selector, supporter1));
        campaignRegistry.requestStakeExit(campaignId, supporter1, 100e6);
    }

    function test_Contract19_Case03_finalizeStakeExit_missingPendingReverts() public {
        _stakeFor(supporter1, 500e6);

        vm.prank(campaignAdmin);
        vm.expectRevert(abi.encodeWithSelector(CampaignRegistry.SupporterStakeMissing.selector, supporter1));
        campaignRegistry.finalizeStakeExit(campaignId, supporter1, 100e6);
    }

    function test_Contract19_Case04_scheduleCheckpoint_invalidWindowReverts() public {
        vm.prank(campaignAdmin);
        vm.expectRevert(CampaignRegistry.InvalidCheckpointWindow.selector);
        campaignRegistry.scheduleCheckpoint(
            campaignId,
            CampaignRegistry.CheckpointInput({
                windowStart: uint64(block.timestamp + 10),
                windowEnd: uint64(block.timestamp + 10),
                executionDeadline: uint64(block.timestamp + 20),
                quorumBps: 5_000
            })
        );

        vm.prank(campaignAdmin);
        vm.expectRevert(CampaignRegistry.InvalidCheckpointWindow.selector);
        campaignRegistry.scheduleCheckpoint(
            campaignId,
            CampaignRegistry.CheckpointInput({
                windowStart: uint64(block.timestamp + 10),
                windowEnd: uint64(block.timestamp + 20),
                executionDeadline: uint64(block.timestamp + 30),
                quorumBps: 0
            })
        );
    }

    function test_Contract19_Case05_updateCheckpointStatus_noneOrNotFoundReverts() public {
        vm.prank(checkpointCouncil);
        vm.expectRevert(
            abi.encodeWithSelector(CampaignRegistry.InvalidCheckpointStatus.selector, GiveTypes.CheckpointStatus.None)
        );
        campaignRegistry.updateCheckpointStatus(campaignId, 0, GiveTypes.CheckpointStatus.None);

        vm.prank(checkpointCouncil);
        vm.expectRevert(abi.encodeWithSelector(CampaignRegistry.CheckpointNotFound.selector, campaignId, 999));
        campaignRegistry.updateCheckpointStatus(campaignId, 999, GiveTypes.CheckpointStatus.Voting);
    }

    function test_Contract19_Case06_updateCheckpointStatus_failedHaltsPayouts() public {
        uint256 index = _scheduleCheckpoint(uint64(block.timestamp + 10), uint64(block.timestamp + 100), 5_000);

        vm.prank(checkpointCouncil);
        campaignRegistry.updateCheckpointStatus(campaignId, index, GiveTypes.CheckpointStatus.Failed);

        GiveTypes.CampaignConfig memory cfg = campaignRegistry.getCampaign(campaignId);
        assertTrue(cfg.payoutsHalted);
    }

    function test_Contract19_Case07_voteOnCheckpoint_guardBranches() public {
        uint64 start = uint64(block.timestamp + 20);
        uint64 end = uint64(block.timestamp + 100);
        uint256 index = _scheduleCheckpoint(start, end, 5_000);

        vm.prank(supporter1);
        vm.expectRevert(
            abi.encodeWithSelector(
                CampaignRegistry.InvalidCheckpointStatus.selector, GiveTypes.CheckpointStatus.Scheduled
            )
        );
        campaignRegistry.voteOnCheckpoint(campaignId, index, true);

        vm.prank(checkpointCouncil);
        campaignRegistry.updateCheckpointStatus(campaignId, index, GiveTypes.CheckpointStatus.Voting);

        vm.warp(start + 1);
        vm.prank(supporter1);
        vm.expectRevert(abi.encodeWithSelector(CampaignRegistry.NoVotingPower.selector, supporter1));
        campaignRegistry.voteOnCheckpoint(campaignId, index, true);

        _stakeFor(supporter1, 1_000e6);

        vm.prank(supporter1);
        vm.expectRevert(abi.encodeWithSelector(CampaignRegistry.NoVotingPower.selector, supporter1));
        campaignRegistry.voteOnCheckpoint(campaignId, index, true);
    }

    function test_Contract19_Case08_voteOnCheckpoint_alreadyVotedReverts() public {
        _stakeFor(supporter1, 1_000e6);

        uint64 start = uint64(block.timestamp + 20);
        uint64 end = uint64(block.timestamp + campaignRegistry.MIN_STAKE_DURATION() + 1_000);
        uint256 index = _scheduleCheckpoint(start, end, 5_000);

        vm.prank(checkpointCouncil);
        campaignRegistry.updateCheckpointStatus(campaignId, index, GiveTypes.CheckpointStatus.Voting);

        vm.warp(block.timestamp + campaignRegistry.MIN_STAKE_DURATION() + 21);
        vm.prank(supporter1);
        campaignRegistry.voteOnCheckpoint(campaignId, index, true);

        vm.prank(supporter1);
        vm.expectRevert(abi.encodeWithSelector(CampaignRegistry.AlreadyVoted.selector, supporter1));
        campaignRegistry.voteOnCheckpoint(campaignId, index, true);
    }

    function test_Contract19_Case09_finalizeCheckpoint_failedSetsPausedAndHalted() public {
        _stakeFor(supporter1, 1_000e6);

        uint64 start = uint64(block.timestamp + 20);
        uint64 end = uint64(block.timestamp + campaignRegistry.MIN_STAKE_DURATION() + 1_000);
        uint256 index = _scheduleCheckpoint(start, end, 8_000);

        vm.prank(checkpointCouncil);
        campaignRegistry.updateCheckpointStatus(campaignId, index, GiveTypes.CheckpointStatus.Voting);

        vm.warp(block.timestamp + campaignRegistry.MIN_STAKE_DURATION() + 21);
        vm.prank(supporter1);
        campaignRegistry.voteOnCheckpoint(campaignId, index, false);

        vm.warp(end + 1);
        vm.prank(campaignAdmin);
        campaignRegistry.finalizeCheckpoint(campaignId, index);

        GiveTypes.CampaignConfig memory cfg = campaignRegistry.getCampaign(campaignId);
        assertTrue(cfg.payoutsHalted);
        assertEq(uint8(cfg.status), uint8(GiveTypes.CampaignStatus.Paused));
    }

    function test_Contract19_Case10_finalizeCheckpoint_successResumesHalted() public {
        _stakeFor(supporter1, 1_000e6);
        _stakeFor(supporter2, 1_000e6);

        GiveTypes.CampaignConfig memory cfgBefore = campaignRegistry.getCampaign(campaignId);
        assertFalse(cfgBefore.payoutsHalted);

        uint64 start1 = uint64(block.timestamp + 20);
        uint64 end1 = uint64(block.timestamp + campaignRegistry.MIN_STAKE_DURATION() + 1_000);
        uint256 failedIndex = _scheduleCheckpoint(start1, end1, 8_000);

        vm.prank(checkpointCouncil);
        campaignRegistry.updateCheckpointStatus(campaignId, failedIndex, GiveTypes.CheckpointStatus.Voting);

        vm.warp(block.timestamp + campaignRegistry.MIN_STAKE_DURATION() + 21);
        vm.prank(supporter1);
        campaignRegistry.voteOnCheckpoint(campaignId, failedIndex, false);

        vm.warp(end1 + 1);
        vm.prank(campaignAdmin);
        campaignRegistry.finalizeCheckpoint(campaignId, failedIndex);

        GiveTypes.CampaignConfig memory cfgFailed = campaignRegistry.getCampaign(campaignId);
        assertTrue(cfgFailed.payoutsHalted);

        uint64 start2 = uint64(block.timestamp + 10);
        uint64 end2 = uint64(block.timestamp + 1_000);
        uint256 successIndex = _scheduleCheckpoint(start2, end2, 5_000);

        vm.prank(checkpointCouncil);
        campaignRegistry.updateCheckpointStatus(campaignId, successIndex, GiveTypes.CheckpointStatus.Voting);

        vm.warp(start2 + 1);
        vm.prank(supporter1);
        campaignRegistry.voteOnCheckpoint(campaignId, successIndex, true);
        vm.prank(supporter2);
        campaignRegistry.voteOnCheckpoint(campaignId, successIndex, true);

        vm.warp(end2 + 1);
        vm.prank(campaignAdmin);
        campaignRegistry.finalizeCheckpoint(campaignId, successIndex);

        GiveTypes.CampaignConfig memory cfgSuccess = campaignRegistry.getCampaign(campaignId);
        assertFalse(cfgSuccess.payoutsHalted);
    }
}
