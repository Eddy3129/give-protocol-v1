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
import {ForkHelperConfig} from "./ForkHelperConfig.sol";
import {GiveTypes} from "../../src/types/GiveTypes.sol";
import {GiveErrors} from "../../src/utils/GiveErrors.sol";
import {ACLManager} from "../../src/governance/ACLManager.sol";
import {StrategyRegistry} from "../../src/registry/StrategyRegistry.sol";
import {CampaignRegistry} from "../../src/registry/CampaignRegistry.sol";
import {NGORegistry} from "../../src/donation/NGORegistry.sol";
import {PayoutRouter} from "../../src/payout/PayoutRouter.sol";
import {GiveVault4626} from "../../src/vault/GiveVault4626.sol";
import {AaveAdapter} from "../../src/adapters/AaveAdapter.sol";
import {IYieldAdapter} from "../../src/interfaces/IYieldAdapter.sol";

contract ForkTest02_CheckpointVoting is ForkBase {
    bytes32 internal constant CAMPAIGN_ID = keccak256("fork_checkpoint_campaign");
    bytes32 internal constant STRATEGY_ID = keccak256("fork_checkpoint_strategy");
    uint256 internal constant DONOR_DEPOSIT = 100_000e6;

    ACLManager internal acl;
    StrategyRegistry internal strategyRegistry;

    CampaignRegistry internal campaignRegistry;
    PayoutRouter internal payoutRouter;
    GiveVault4626 internal vault;
    AaveAdapter internal adapter;

    IERC20 internal usdc;

    address internal admin;
    address internal proposer;
    address internal checkpointNgo;
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

        ForkHelperConfig.RegistrySuite memory suite = ForkHelperConfig.initAllRegistries(admin);
        acl = suite.acl;
        strategyRegistry = suite.strategyRegistry;
        campaignRegistry = suite.campaignRegistry;
        NGORegistry ngoRegistry = suite.ngoRegistry;

        vm.startPrank(admin);
        ForkHelperConfig.grantCoreProtocolRoles(acl, admin, checkpointCouncil);
        ForkHelperConfig.grantNgoRegistryRoles(acl, admin, address(0));
        ForkHelperConfig.wireCampaignNgoRegistry(campaignRegistry, ngoRegistry);
        checkpointNgo = makeAddr("checkpoint_ngo");
        ForkHelperConfig.addApprovedNgo(
            ngoRegistry, checkpointNgo, "ipfs://checkpoint-ngo", keccak256("fork02-checkpoint-ngo")
        );
        vm.stopPrank();

        vm.prank(admin);
        strategyRegistry.registerStrategy(
            StrategyRegistry.StrategyInput({
                id: STRATEGY_ID,
                adapter: address(1),
                riskTier: keccak256("LOW"),
                maxTvl: type(uint256).max,
                metadataHash: keccak256("fork02-strategy")
            })
        );

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
        _finalizeAfterVotingWindow(checkpointIndex, true, true);

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
        _finalizeAfterVotingWindow(failedIndex, true, true);

        GiveTypes.CampaignConfig memory afterFail = campaignRegistry.getCampaign(CAMPAIGN_ID);
        assertTrue(afterFail.payoutsHalted, "checkpoint fail should halt payouts");

        uint256 successIndex = _scheduleCheckpoint(100);
        _openVoting(successIndex);

        vm.prank(supporter1);
        campaignRegistry.voteOnCheckpoint(CAMPAIGN_ID, successIndex, true);
        vm.prank(supporter2);
        campaignRegistry.voteOnCheckpoint(CAMPAIGN_ID, successIndex, true);

        _finalizeAfterVotingWindow(successIndex, true, false);

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
        uint256 submissionDeposit = ForkHelperConfig.CAMPAIGN_SUBMISSION_DEPOSIT;

        CampaignRegistry.CampaignInput memory input = CampaignRegistry.CampaignInput({
            id: CAMPAIGN_ID,
            payoutRecipient: checkpointNgo,
            strategyId: STRATEGY_ID,
            metadataHash: keccak256("checkpoint-campaign"),
            metadataCID: "ipfs://checkpoint-campaign",
            targetStake: 1_000_000e6,
            minStake: 1_000e6,
            fundraisingStart: uint64(block.timestamp),
            fundraisingEnd: uint64(block.timestamp + 60 days)
        });

        vm.deal(checkpointNgo, 1 ether);
        vm.prank(checkpointNgo);
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

    function _finalizeAfterVotingWindow(uint256 checkpointIndex, bool expectPayoutsHaltedEvent, bool haltedValue)
        internal
    {
        (, uint64 windowEnd,,,,) = campaignRegistry.getCheckpoint(CAMPAIGN_ID, checkpointIndex);
        vm.warp(uint256(windowEnd) + 1);

        if (expectPayoutsHaltedEvent) {
            vm.expectEmit(true, true, false, true);
            emit CampaignRegistry.PayoutsHalted(CAMPAIGN_ID, haltedValue);
        }

        vm.prank(admin);
        campaignRegistry.finalizeCheckpoint(CAMPAIGN_ID, checkpointIndex);
    }
}
