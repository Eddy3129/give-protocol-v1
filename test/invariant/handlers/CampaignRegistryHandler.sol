// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";

import {CampaignRegistry} from "../../../src/registry/CampaignRegistry.sol";
import {IACLManager} from "../../../src/interfaces/IACLManager.sol";
import {GiveTypes} from "../../../src/types/GiveTypes.sol";

// ─── Minimal mocks ───────────────────────────────────────────────────────────

/// @notice Permissive ACL: grants every role to every address.
///         Allows the handler to call any role-gated function as any actor.
contract CRMockACL is IACLManager {
    bytes32 private constant CAMPAIGN_ADMIN = keccak256("CAMPAIGN_ADMIN_ROLE");
    bytes32 private constant CAMPAIGN_CURATOR = keccak256("CAMPAIGN_CURATOR_ROLE");
    bytes32 private constant CAMPAIGN_CREATOR = keccak256("CAMPAIGN_CREATOR_ROLE");
    bytes32 private constant CHECKPOINT_COUNCIL = keccak256("CHECKPOINT_COUNCIL_ROLE");
    bytes32 private constant PROTOCOL_ADMIN = keccak256("PROTOCOL_ADMIN_ROLE");
    bytes32 private constant STRATEGY_ADMIN = keccak256("STRATEGY_ADMIN_ROLE");
    bytes32 private constant ROLE_UPGRADER = keccak256("ROLE_UPGRADER");

    function hasRole(bytes32, address) external pure returns (bool) { return true; }

    function campaignAdminRole() external pure returns (bytes32) { return CAMPAIGN_ADMIN; }
    function campaignCuratorRole() external pure returns (bytes32) { return CAMPAIGN_CURATOR; }
    function campaignCreatorRole() external pure returns (bytes32) { return CAMPAIGN_CREATOR; }
    function checkpointCouncilRole() external pure returns (bytes32) { return CHECKPOINT_COUNCIL; }
    function protocolAdminRole() external pure returns (bytes32) { return PROTOCOL_ADMIN; }
    function strategyAdminRole() external pure returns (bytes32) { return STRATEGY_ADMIN; }

    // Satisfy interface — unused in invariant tests
    function initialize(address, address) external {}
    function createRole(bytes32, address) external {}
    function grantRole(bytes32, address) external {}
    function revokeRole(bytes32, address) external {}
    function proposeRoleAdmin(bytes32, address) external {}
    function acceptRoleAdmin(bytes32) external {}
    function roleAdmin(bytes32) external pure returns (address) { return address(0); }
    function getRoleMembers(bytes32) external pure returns (address[] memory) {
        return new address[](0);
    }
    function roleExists(bytes32) external pure returns (bool) { return true; }
    function canonicalRoles() external pure returns (bytes32[] memory) {
        return new bytes32[](0);
    }
    function isCanonicalRole(bytes32) external pure returns (bool) { return true; }
}

/// @notice Returns a single valid active strategy for any strategyId.
contract CRMockStrategyRegistry {
    bytes32 public immutable strategyId;

    constructor(bytes32 sid) { strategyId = sid; }

    function getStrategy(bytes32) external view returns (GiveTypes.StrategyConfig memory cfg) {
        uint256[50] memory gap;
        cfg.id = strategyId;
        cfg.status = GiveTypes.StrategyStatus.Active;
        cfg.exists = true;
        cfg.__gap = gap;
    }
}

// ─── Handler ─────────────────────────────────────────────────────────────────

/// @title CampaignRegistryHandler
/// @notice Exercises the CampaignRegistry lifecycle: submit, approve/reject,
///         stake, checkpoint scheduling, voting, and finalization.
///         Tracks ghost variables for invariant verification.
contract CampaignRegistryHandler is Test {
    // ── Contract under test ──────────────────────────────────────────
    CampaignRegistry public immutable registry;

    // ── Campaign data ────────────────────────────────────────────────
    bytes32 public constant CAMPAIGN_ID = keccak256("invariant_campaign_a");
    bytes32 public constant STRATEGY_ID = keccak256("aave_usdc_strategy");
    uint256 public constant SUBMISSION_DEPOSIT = 0.005 ether;
    uint64 public constant MIN_STAKE_DURATION = 1 hours;

    // ── Actors ───────────────────────────────────────────────────────
    address[3] internal _stakers;
    address internal immutable _admin;
    address internal immutable _ngo;

    // ── Ghost variables ──────────────────────────────────────────────
    /// @notice Total amount recorded as stake deposits (minus finalised exits)
    ///         Should equal getCampaign(CAMPAIGN_ID).totalStaked
    uint256 public ghost_totalStaked;

    /// @notice Active portion of the stake pool (pre-exit-request)
    uint256 public ghost_totalActive;

    /// @notice Portion in pending-exit state
    uint256 public ghost_totalPendingExit;

    /// @notice Whether a Failed checkpoint has ever been finalised for CAMPAIGN_ID
    bool public ghost_hasFailedCheckpoint;

    /// @notice Whether the campaign has been submitted
    bool public ghost_campaignSubmitted;

    /// @notice Whether the campaign has been approved or rejected (deposit should be 0)
    bool public ghost_campaignDecided;

    // ── Internal state ───────────────────────────────────────────────
    bool internal _campaignApproved;
    uint256 internal _checkpointIndex;
    bool internal _checkpointScheduled;
    bool internal _checkpointInVoting;

    constructor() {
        _admin = makeAddr("cr_admin");
        _ngo = makeAddr("cr_ngo");
        _stakers[0] = makeAddr("cr_staker0");
        _stakers[1] = makeAddr("cr_staker1");
        _stakers[2] = makeAddr("cr_staker2");

        // Fund handler with ETH for campaign submissions
        vm.deal(address(this), 10 ether);

        CRMockACL acl = new CRMockACL();
        CRMockStrategyRegistry stratReg = new CRMockStrategyRegistry(STRATEGY_ID);

        registry = new CampaignRegistry();
        registry.initialize(address(acl), address(stratReg));

        // Submit and approve the campaign once in the constructor so the main
        // lifecycle (stake/checkpoint) is available to the fuzzer immediately.
        _submitCampaign();
        registry.approveCampaign(CAMPAIGN_ID, _admin);
        ghost_campaignSubmitted = true;
        ghost_campaignDecided = true;
        _campaignApproved = true;
    }

    // ── Handler actions ──────────────────────────────────────────────

    /// @notice Record a stake deposit for an actor (simulates a vault depositing
    ///         on behalf of a user after they deposit into the campaign vault).
    function recordStake(uint8 stakerSeed, uint256 amount) external {
        if (!_campaignApproved) return;
        address staker = _stakers[stakerSeed % 3];
        amount = bound(amount, 1e6, 100_000e6);

        registry.recordStakeDeposit(CAMPAIGN_ID, staker, amount);

        ghost_totalActive += amount;
        ghost_totalStaked += amount;
    }

    /// @notice Request an exit for a portion of a staker's active stake.
    function requestExit(uint8 stakerSeed, uint256 amount) external {
        if (!_campaignApproved) return;
        address staker = _stakers[stakerSeed % 3];

        GiveTypes.SupporterStake memory pos = registry.getStakePosition(CAMPAIGN_ID, staker);
        if (pos.shares == 0) return;
        amount = bound(amount, 1, pos.shares);

        registry.requestStakeExit(CAMPAIGN_ID, staker, amount);

        ghost_totalActive -= amount;
        ghost_totalPendingExit += amount;
    }

    /// @notice Finalize a pending exit for a staker.
    function finalizeExit(uint8 stakerSeed, uint256 amount) external {
        if (!_campaignApproved) return;
        address staker = _stakers[stakerSeed % 3];

        GiveTypes.SupporterStake memory pos = registry.getStakePosition(CAMPAIGN_ID, staker);
        if (pos.pendingWithdrawal == 0) return;
        amount = bound(amount, 1, pos.pendingWithdrawal);

        registry.finalizeStakeExit(CAMPAIGN_ID, staker, amount);

        ghost_totalPendingExit -= amount;
        ghost_totalStaked -= amount;
    }

    /// @notice Schedule a checkpoint for the campaign.
    function scheduleCheckpoint(uint64 windowDuration, uint16 quorumBps) external {
        if (!_campaignApproved) return;
        if (_checkpointScheduled) return; // Only one active checkpoint at a time

        windowDuration = uint64(bound(windowDuration, 1 hours, 7 days));
        quorumBps = uint16(bound(quorumBps, 100, 5_000));

        uint64 windowStart = uint64(block.timestamp + 1);
        uint64 windowEnd = windowStart + windowDuration;
        uint64 deadline = windowEnd + 1 days;

        CampaignRegistry.CheckpointInput memory input = CampaignRegistry.CheckpointInput({
            windowStart: windowStart,
            windowEnd: windowEnd,
            executionDeadline: deadline,
            quorumBps: quorumBps
        });

        _checkpointIndex = registry.scheduleCheckpoint(CAMPAIGN_ID, input);
        _checkpointScheduled = true;
    }

    /// @notice Move checkpoint to Voting state and vote (after MIN_STAKE_DURATION).
    function voteOnCheckpoint(bool support) external {
        if (!_checkpointScheduled || _checkpointInVoting) return;

        // Transition checkpoint to Voting
        registry.updateCheckpointStatus(CAMPAIGN_ID, _checkpointIndex, GiveTypes.CheckpointStatus.Voting);
        _checkpointInVoting = true;

        // Ensure MIN_STAKE_DURATION has elapsed for stakers (flash-loan protection)
        skip(MIN_STAKE_DURATION + 1);

        // Have all stakers vote if they have a stake position
        for (uint256 i = 0; i < 3; i++) {
            GiveTypes.SupporterStake memory pos =
                registry.getStakePosition(CAMPAIGN_ID, _stakers[i]);
            if (!pos.exists) continue;

            vm.prank(_stakers[i]);
            try registry.voteOnCheckpoint(CAMPAIGN_ID, _checkpointIndex, support) {} catch {}
        }
    }

    /// @notice Finalize the current checkpoint after its voting window closes.
    function finalizeCheckpoint() external {
        if (!_checkpointInVoting) return;

        // Warp past the voting window end
        (,uint64 windowEnd,,,, ) = registry.getCheckpoint(CAMPAIGN_ID, _checkpointIndex);
        if (block.timestamp <= windowEnd) {
            vm.warp(windowEnd + 1);
        }

        registry.finalizeCheckpoint(CAMPAIGN_ID, _checkpointIndex);

        (, , , , GiveTypes.CheckpointStatus status, ) =
            registry.getCheckpoint(CAMPAIGN_ID, _checkpointIndex);

        if (status == GiveTypes.CheckpointStatus.Failed) {
            ghost_hasFailedCheckpoint = true;
        }

        _checkpointScheduled = false;
        _checkpointInVoting = false;
    }

    /// @notice Advance time to allow timelocks to expire.
    function advanceTime(uint256 seconds_) external {
        skip(bound(seconds_, 1, 14 days));
    }

    // ── Internal helpers ─────────────────────────────────────────────

    function _submitCampaign() internal {
        CampaignRegistry.CampaignInput memory input = CampaignRegistry.CampaignInput({
            id: CAMPAIGN_ID,
            payoutRecipient: _ngo,
            strategyId: STRATEGY_ID,
            metadataHash: keccak256("metadata"),
            metadataCID: "ipfs://QmTest",
            targetStake: 1_000_000e6,
            minStake: 1_000e6,
            fundraisingStart: uint64(block.timestamp),
            fundraisingEnd: 0
        });

        registry.submitCampaign{value: SUBMISSION_DEPOSIT}(input);
    }

    // ── Getters ──────────────────────────────────────────────────────

    function staker(uint8 idx) external view returns (address) {
        return _stakers[idx % 3];
    }
}
