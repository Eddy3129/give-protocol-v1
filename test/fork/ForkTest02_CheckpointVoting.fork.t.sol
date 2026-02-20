// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title   ForkTest02_CheckpointVoting
 * @author  GIVE Labs
 * @notice  Fork test for Phase 5.5 GAP-5: checkpoint governance end-to-end
 * @dev     Tests campaign checkpoint lifecycle on live Base mainnet fork:
 *          - Checkpoint proposal and scheduling
 *          - Multi-supporter voting with stake-weighted votes
 *          - Checkpoint finalization and payout halt/resume
 *          - Recovery paths for failed checkpoints
 */

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {ForkBase} from "./ForkBase.t.sol";
import {ForkAddresses} from "./ForkAddresses.sol";
import {GiveTypes} from "../../src/types/GiveTypes.sol";
import {GiveErrors} from "../../src/utils/GiveErrors.sol";
import {CampaignRegistry} from "../../src/registry/CampaignRegistry.sol";
import {PayoutRouter} from "../../src/payout/PayoutRouter.sol";
import {GiveVault4626} from "../../src/vault/GiveVault4626.sol";
import {AaveAdapter} from "../../src/adapters/AaveAdapter.sol";
import {IYieldAdapter} from "../../src/interfaces/IYieldAdapter.sol";

contract ForkMockACLForCheckpoint {
    mapping(bytes32 => mapping(address => bool)) internal roleMembers;

    bytes32 internal constant ROLE_PROTOCOL_ADMIN = keccak256("ROLE_PROTOCOL_ADMIN");
    bytes32 internal constant ROLE_STRATEGY_ADMIN = keccak256("ROLE_STRATEGY_ADMIN");
    bytes32 internal constant ROLE_CAMPAIGN_ADMIN = keccak256("ROLE_CAMPAIGN_ADMIN");
    bytes32 internal constant ROLE_CAMPAIGN_CREATOR = keccak256("ROLE_CAMPAIGN_CREATOR");
    bytes32 internal constant ROLE_CAMPAIGN_CURATOR = keccak256("ROLE_CAMPAIGN_CURATOR");
    bytes32 internal constant ROLE_CHECKPOINT_COUNCIL = keccak256("ROLE_CHECKPOINT_COUNCIL");

    function grantRole(bytes32 role, address account) external {
        roleMembers[role][account] = true;
    }

    function hasRole(bytes32 role, address account) external view returns (bool) {
        return roleMembers[role][account];
    }

    function protocolAdminRole() external pure returns (bytes32) {
        return ROLE_PROTOCOL_ADMIN;
    }

    function strategyAdminRole() external pure returns (bytes32) {
        return ROLE_STRATEGY_ADMIN;
    }

    function campaignAdminRole() external pure returns (bytes32) {
        return ROLE_CAMPAIGN_ADMIN;
    }

    function campaignCreatorRole() external pure returns (bytes32) {
        return ROLE_CAMPAIGN_CREATOR;
    }

    function campaignCuratorRole() external pure returns (bytes32) {
        return ROLE_CAMPAIGN_CURATOR;
    }

    function checkpointCouncilRole() external pure returns (bytes32) {
        return ROLE_CHECKPOINT_COUNCIL;
    }
}

contract ForkMockStrategyRegistry {
    function getStrategy(bytes32 strategyId) external view returns (GiveTypes.StrategyConfig memory cfg) {
        uint256[50] memory gap;
        cfg.id = strategyId;
        cfg.adapter = address(1);
        cfg.creator = address(this);
        cfg.metadataHash = keccak256("mock-strategy");
        cfg.riskTier = keccak256("low");
        cfg.maxTvl = type(uint256).max;
        cfg.createdAt = uint64(block.timestamp);
        cfg.updatedAt = uint64(block.timestamp);
        cfg.status = GiveTypes.StrategyStatus.Active;
        cfg.exists = true;
        cfg.__gap = gap;
    }
}

contract ForkTest02_CheckpointVoting is ForkBase {
    bytes32 internal constant CAMPAIGN_ID = keccak256("fork_checkpoint_campaign");
    bytes32 internal constant STRATEGY_ID = keccak256("fork_checkpoint_strategy");
    uint256 internal constant DONOR_DEPOSIT = 100_000e6;

    ForkMockACLForCheckpoint internal acl;
    ForkMockStrategyRegistry internal strategyRegistry;

    CampaignRegistry internal campaignRegistry;
    PayoutRouter internal payoutRouter;
    GiveVault4626 internal vault;
    AaveAdapter internal adapter;

    IERC20 internal usdc;

    address internal admin;
    address internal proposer;
    address internal checkpointCouncil;
    address internal supporter1;
    address internal supporter2;

    function setUp() public override {
        super.setUp();
        if (!_forkActive) return;

        usdc = IERC20(ForkAddresses.USDC);

        admin = address(0x1001);
        proposer = address(0x1002);
        checkpointCouncil = address(0x1003);
        supporter1 = address(0x1004);
        supporter2 = address(0x1005);

        acl = new ForkMockACLForCheckpoint();
        strategyRegistry = new ForkMockStrategyRegistry();

        acl.grantRole(acl.campaignAdminRole(), admin);
        acl.grantRole(acl.campaignCuratorRole(), admin);
        acl.grantRole(acl.checkpointCouncilRole(), checkpointCouncil);

        campaignRegistry = new CampaignRegistry();
        campaignRegistry.initialize(address(acl), address(strategyRegistry));

        payoutRouter = new PayoutRouter();
        vm.startPrank(admin);
        payoutRouter.initialize(admin, address(acl), address(campaignRegistry), admin, admin, 250);
        payoutRouter.grantRole(payoutRouter.VAULT_MANAGER_ROLE(), admin);
        vm.stopPrank();

        vault = new GiveVault4626();
        vm.prank(admin);
        vault.initialize(ForkAddresses.USDC, "Checkpoint USDC Vault", "cpUSDC", admin, address(acl), address(vault));

        adapter = new AaveAdapter(ForkAddresses.USDC, address(vault), ForkAddresses.AAVE_POOL, admin);

        vm.startPrank(admin);
        vault.setActiveAdapter(IYieldAdapter(address(adapter)));
        vault.setDonationRouter(address(payoutRouter));
        payoutRouter.registerCampaignVault(address(vault), CAMPAIGN_ID);
        payoutRouter.setAuthorizedCaller(address(vault), true);
        vm.stopPrank();

        _submitApproveAndActivateCampaign();
    }

    function test_failed_checkpoint_halts_payouts_and_blocks_harvest() public requiresFork {
        _depositToVault(supporter1, DONOR_DEPOSIT);
        _recordStake(supporter1, DONOR_DEPOSIT);

        uint256 checkpointIndex = _scheduleCheckpoint(9000);
        _openVoting(checkpointIndex);
        _finalizeAfterVotingWindow(checkpointIndex);

        GiveTypes.CampaignConfig memory campaign = campaignRegistry.getCampaign(CAMPAIGN_ID);
        assertTrue(campaign.payoutsHalted, "payouts should be halted after failed checkpoint");

        vm.warp(block.timestamp + 30 days);
        vm.expectRevert(GiveErrors.OperationNotAllowed.selector);
        vault.harvest();
    }

    function test_succeeded_checkpoint_resumes_payouts_and_harvest_succeeds() public requiresFork {
        _depositToVault(supporter1, DONOR_DEPOSIT);
        _recordStake(supporter1, DONOR_DEPOSIT);
        _recordStake(supporter2, DONOR_DEPOSIT / 2);

        uint256 failedIndex = _scheduleCheckpoint(9000);
        _openVoting(failedIndex);
        _finalizeAfterVotingWindow(failedIndex);

        GiveTypes.CampaignConfig memory afterFail = campaignRegistry.getCampaign(CAMPAIGN_ID);
        assertTrue(afterFail.payoutsHalted, "checkpoint fail should halt payouts");

        uint256 successIndex = _scheduleCheckpoint(100);
        _openVoting(successIndex);

        vm.prank(supporter1);
        campaignRegistry.voteOnCheckpoint(CAMPAIGN_ID, successIndex, true);
        vm.prank(supporter2);
        campaignRegistry.voteOnCheckpoint(CAMPAIGN_ID, successIndex, true);

        _finalizeAfterVotingWindow(successIndex);

        GiveTypes.CampaignConfig memory afterSuccess = campaignRegistry.getCampaign(CAMPAIGN_ID);
        assertFalse(afterSuccess.payoutsHalted, "successful checkpoint should resume payouts");

        vm.warp(block.timestamp + 30 days);
        (uint256 profit, uint256 loss) = vault.harvest();

        assertEq(loss, 0, "unexpected loss on Aave harvest path");
        assertGt(profit, 0, "harvest should realize positive yield after resume");
    }

    function test_vote_blocked_before_min_stake_duration() public requiresFork {
        _recordStake(supporter1, DONOR_DEPOSIT / 10);

        uint256 checkpointIndex = _scheduleCheckpoint(5000);
        _openVoting(checkpointIndex);

        vm.prank(supporter1);
        vm.expectRevert(abi.encodeWithSelector(CampaignRegistry.NoVotingPower.selector, supporter1));
        campaignRegistry.voteOnCheckpoint(CAMPAIGN_ID, checkpointIndex, true);
    }

    function _submitApproveAndActivateCampaign() internal {
        vm.deal(proposer, 1 ether);
        uint256 submissionDeposit = campaignRegistry.MIN_SUBMISSION_DEPOSIT();

        CampaignRegistry.CampaignInput memory input = CampaignRegistry.CampaignInput({
            id: CAMPAIGN_ID,
            payoutRecipient: makeAddr("checkpoint_ngo"),
            strategyId: STRATEGY_ID,
            metadataHash: keccak256("checkpoint-campaign"),
            metadataCID: "ipfs://checkpoint-campaign",
            targetStake: 1_000_000e6,
            minStake: 1_000e6,
            fundraisingStart: uint64(block.timestamp),
            fundraisingEnd: uint64(block.timestamp + 60 days)
        });

        vm.prank(proposer);
        campaignRegistry.submitCampaign{value: submissionDeposit}(input);

        vm.startPrank(admin);
        campaignRegistry.approveCampaign(CAMPAIGN_ID, admin);
        campaignRegistry.setCampaignStatus(CAMPAIGN_ID, GiveTypes.CampaignStatus.Active);
        campaignRegistry.setCampaignVault(CAMPAIGN_ID, address(vault), keccak256("flex"));
        vm.stopPrank();
    }

    function _depositToVault(address user, uint256 amount) internal {
        deal(ForkAddresses.USDC, user, amount);

        vm.startPrank(user);
        usdc.approve(address(vault), amount);
        vault.deposit(amount, user);
        vm.stopPrank();
    }

    function _recordStake(address supporter, uint256 amount) internal {
        vm.prank(admin);
        campaignRegistry.recordStakeDeposit(CAMPAIGN_ID, supporter, amount);
    }

    function _scheduleCheckpoint(uint16 quorumBps) internal returns (uint256 index) {
        uint64 nowTs = uint64(block.timestamp);
        uint64 windowStart = nowTs + 1;
        uint64 windowEnd = nowTs + 172_800;

        CampaignRegistry.CheckpointInput memory input = CampaignRegistry.CheckpointInput({
            windowStart: windowStart, windowEnd: windowEnd, executionDeadline: windowEnd + 86_400, quorumBps: quorumBps
        });

        vm.prank(admin);
        index = campaignRegistry.scheduleCheckpoint(CAMPAIGN_ID, input);
    }

    function _openVoting(uint256 checkpointIndex) internal {
        (uint64 windowStart,,,,,) = campaignRegistry.getCheckpoint(CAMPAIGN_ID, checkpointIndex);
        vm.warp(uint256(windowStart) + 1);

        vm.prank(checkpointCouncil);
        campaignRegistry.updateCheckpointStatus(CAMPAIGN_ID, checkpointIndex, GiveTypes.CheckpointStatus.Voting);
    }

    function _finalizeAfterVotingWindow(uint256 checkpointIndex) internal {
        (, uint64 windowEnd,,,,) = campaignRegistry.getCheckpoint(CAMPAIGN_ID, checkpointIndex);
        vm.warp(uint256(windowEnd) + 1);

        vm.prank(admin);
        campaignRegistry.finalizeCheckpoint(CAMPAIGN_ID, checkpointIndex);
    }
}
