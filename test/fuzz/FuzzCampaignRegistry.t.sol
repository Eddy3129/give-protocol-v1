// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";

import {CampaignRegistry} from "../../src/registry/CampaignRegistry.sol";
import {GiveTypes} from "../../src/types/GiveTypes.sol";

contract FuzzACL {
    mapping(bytes32 => mapping(address => bool)) internal roles;

    bytes32 public constant CAMPAIGN_ADMIN_ROLE = keccak256("ROLE_CAMPAIGN_ADMIN");
    bytes32 public constant CAMPAIGN_CURATOR_ROLE = keccak256("ROLE_CAMPAIGN_CURATOR");
    bytes32 public constant CHECKPOINT_COUNCIL_ROLE = keccak256("ROLE_CHECKPOINT_COUNCIL");

    function setRole(bytes32 role, address account, bool enabled) external {
        roles[role][account] = enabled;
    }

    function hasRole(bytes32 role, address account) external view returns (bool) {
        return roles[role][account];
    }

    function campaignAdminRole() external pure returns (bytes32) {
        return CAMPAIGN_ADMIN_ROLE;
    }

    function campaignCuratorRole() external pure returns (bytes32) {
        return CAMPAIGN_CURATOR_ROLE;
    }

    function campaignCreatorRole() external pure returns (bytes32) {
        return keccak256("ROLE_CAMPAIGN_CREATOR");
    }

    function checkpointCouncilRole() external pure returns (bytes32) {
        return CHECKPOINT_COUNCIL_ROLE;
    }
}

contract FuzzStrategyRegistry {
    mapping(bytes32 => GiveTypes.StrategyConfig) internal _strategies;

    function setActiveStrategy(bytes32 strategyId) external {
        _strategies[strategyId] = GiveTypes.StrategyConfig({
            id: strategyId,
            adapter: address(this),
            creator: address(this),
            metadataHash: bytes32(0),
            riskTier: bytes32(0),
            maxTvl: type(uint256).max,
            createdAt: uint64(block.timestamp),
            updatedAt: uint64(block.timestamp),
            status: GiveTypes.StrategyStatus.Active,
            exists: true,
            __gap: [
                uint256(0),
                0,
                0,
                0,
                0,
                0,
                0,
                0,
                0,
                0,
                0,
                0,
                0,
                0,
                0,
                0,
                0,
                0,
                0,
                0,
                0,
                0,
                0,
                0,
                0,
                0,
                0,
                0,
                0,
                0,
                0,
                0,
                0,
                0,
                0,
                0,
                0,
                0,
                0,
                0,
                0,
                0,
                0,
                0,
                0,
                0,
                0,
                0,
                0,
                0
            ]
        });
    }

    function getStrategy(bytes32 strategyId) external view returns (GiveTypes.StrategyConfig memory) {
        return _strategies[strategyId];
    }
}

contract FuzzCampaignRegistry is Test {
    CampaignRegistry private registry;
    FuzzACL private acl;
    FuzzStrategyRegistry private strategyRegistry;

    address private admin;
    address private curator;
    address private council;
    address private proposer;

    bytes32 private campaignId;
    bytes32 private strategyId;

    function setUp() public {
        admin = makeAddr("admin");
        curator = makeAddr("curator");
        council = makeAddr("council");
        proposer = makeAddr("proposer");

        acl = new FuzzACL();
        strategyRegistry = new FuzzStrategyRegistry();

        acl.setRole(acl.CAMPAIGN_ADMIN_ROLE(), admin, true);
        acl.setRole(acl.CAMPAIGN_CURATOR_ROLE(), curator, true);
        acl.setRole(acl.CHECKPOINT_COUNCIL_ROLE(), council, true);

        registry = new CampaignRegistry();
        registry.initialize(address(acl), address(strategyRegistry));

        campaignId = keccak256("fuzz.campaign.registry");
        strategyId = keccak256("fuzz.strategy.registry");

        strategyRegistry.setActiveStrategy(strategyId);

        vm.deal(proposer, 1 ether);
        vm.prank(proposer);
        registry.submitCampaign{value: 0.005 ether}(
            CampaignRegistry.CampaignInput({
                id: campaignId,
                payoutRecipient: makeAddr("ngo"),
                strategyId: strategyId,
                metadataHash: keccak256("fuzz"),
                metadataCID: "QmFuzzCampaignRegistry",
                targetStake: 1_000_000e6,
                minStake: 1e6,
                fundraisingStart: uint64(block.timestamp),
                fundraisingEnd: uint64(block.timestamp + 30 days)
            })
        );

        vm.prank(admin);
        registry.approveCampaign(campaignId, curator);
    }

    function testFuzz_checkpoint_voting_eligibility(uint256 stakeAmount, uint64 stakeDelay, bool support) public {
        uint256 boundedStake = bound(stakeAmount, 1, 1_000_000e6);
        address supporter = makeAddr("supporter");

        vm.prank(curator);
        registry.recordStakeDeposit(campaignId, supporter, boundedStake);

        uint64 start = uint64(block.timestamp + 1);
        uint64 end = uint64(block.timestamp + 3 days);

        vm.prank(admin);
        registry.scheduleCheckpoint(
            campaignId,
            CampaignRegistry.CheckpointInput({
                windowStart: start,
                windowEnd: end,
                executionDeadline: uint64(end + 1 days),
                quorumBps: 5_000
            })
        );

        vm.prank(council);
        registry.updateCheckpointStatus(campaignId, 0, GiveTypes.CheckpointStatus.Voting);

        uint256 voteTime = uint256(start) + uint256(stakeDelay);
        if (voteTime > end - 1) {
            voteTime = end - 1;
        }
        vm.warp(voteTime);

        bool shouldRevert = uint256(stakeDelay) + 1 < registry.MIN_STAKE_DURATION();

        if (shouldRevert) {
            vm.expectRevert(abi.encodeWithSelector(CampaignRegistry.NoVotingPower.selector, supporter));
            vm.prank(supporter);
            registry.voteOnCheckpoint(campaignId, 0, support);
            return;
        }

        vm.prank(supporter);
        registry.voteOnCheckpoint(campaignId, 0, support);
    }

    function testFuzz_quorum_finalization(uint208 votesFor, uint208 votesAgainst, uint16 quorumBps) public {
        uint256 forStake = bound(uint256(votesFor), 1, 1_000_000e6);
        uint256 againstStake = bound(uint256(votesAgainst), 1, 1_000_000e6);
        uint16 boundedQuorum = uint16(bound(uint256(quorumBps), 1, 10_000));

        address supporterFor = makeAddr("supporter-for");
        address supporterAgainst = makeAddr("supporter-against");

        vm.prank(curator);
        registry.recordStakeDeposit(campaignId, supporterFor, forStake);
        vm.prank(curator);
        registry.recordStakeDeposit(campaignId, supporterAgainst, againstStake);

        uint64 start = uint64(block.timestamp + 1);
        uint64 end = uint64(block.timestamp + 2 days);

        vm.prank(admin);
        registry.scheduleCheckpoint(
            campaignId,
            CampaignRegistry.CheckpointInput({
                windowStart: start,
                windowEnd: end,
                executionDeadline: uint64(end + 1 days),
                quorumBps: boundedQuorum
            })
        );

        vm.prank(council);
        registry.updateCheckpointStatus(campaignId, 0, GiveTypes.CheckpointStatus.Voting);

        vm.warp(block.timestamp + registry.MIN_STAKE_DURATION() + 2);

        vm.prank(supporterFor);
        registry.voteOnCheckpoint(campaignId, 0, true);
        vm.prank(supporterAgainst);
        registry.voteOnCheckpoint(campaignId, 0, false);

        vm.warp(end + 1);
        vm.prank(admin);
        registry.finalizeCheckpoint(campaignId, 0);

        (,,,, GiveTypes.CheckpointStatus status, uint256 eligibleVotes) = registry.getCheckpoint(campaignId, 0);

        uint256 totalCast = forStake + againstStake;
        bool quorumMet = eligibleVotes == 0 ? true : totalCast >= (uint256(boundedQuorum) * eligibleVotes) / 10_000;
        GiveTypes.CheckpointStatus expected = quorumMet && forStake > againstStake
            ? GiveTypes.CheckpointStatus.Succeeded
            : GiveTypes.CheckpointStatus.Failed;

        assertEq(uint8(status), uint8(expected));
    }
}
