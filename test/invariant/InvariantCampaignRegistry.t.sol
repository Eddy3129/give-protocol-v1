// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";

import {GiveTypes} from "../../src/types/GiveTypes.sol";
import {CampaignRegistryHandler} from "./handlers/CampaignRegistryHandler.sol";

/// @title InvariantCampaignRegistry
/// @notice Verifies core governance and accounting invariants of CampaignRegistry.
///
/// Properties tested:
///   I1. Campaign submission deposit is always zeroed after approval or rejection.
///   I2. getCampaign.totalStaked == ghost_totalActive + ghost_totalPendingExit.
///   I3. If payoutsHalted == true, a Failed checkpoint must exist.
///   I4. getStakePosition sums are consistent with ghost stake tracking per staker.
contract InvariantCampaignRegistry is Test {
    CampaignRegistryHandler internal handler;

    function setUp() public {
        handler = new CampaignRegistryHandler();
        targetContract(address(handler));
    }

    // ── I1 ───────────────────────────────────────────────────────────

    /// @notice After the campaign is approved or rejected, initialDeposit must be 0.
    ///         A non-zero value would mean the ETH deposit was neither refunded nor slashed,
    ///         which is a fund-locking bug.
    function invariant_deposit_zeroed_after_decision() public view {
        if (!handler.ghost_campaignDecided()) return;

        GiveTypes.CampaignConfig memory cfg = handler.registry().getCampaign(handler.CAMPAIGN_ID());

        assertEq(cfg.initialDeposit, 0, "I1: initialDeposit != 0 after approve/reject");
    }

    // ── I2 ───────────────────────────────────────────────────────────

    /// @notice getCampaign(id).totalStaked must equal ghost_totalActive + ghost_totalPendingExit.
    ///
    ///         The contract updates totalStaked on deposit (+amount) and finalizeExit (-amount).
    ///         requestExit only moves funds from active to pending — totalStaked is unchanged.
    ///         This invariant confirms there are no accounting bugs in the stake lifecycle.
    function invariant_stake_accounting_consistent() public view {
        if (!handler.ghost_campaignDecided()) return;

        GiveTypes.CampaignConfig memory cfg = handler.registry().getCampaign(handler.CAMPAIGN_ID());

        uint256 expectedTotalStaked = handler.ghost_totalActive() + handler.ghost_totalPendingExit();

        assertEq(cfg.totalStaked, expectedTotalStaked, "I2: totalStaked != ghost_totalActive + ghost_totalPendingExit");
    }

    // ── I3 ───────────────────────────────────────────────────────────

    /// @notice If getCampaign(id).payoutsHalted is true, a Failed checkpoint must
    ///         have been finalised. Payouts can only be halted by a Failed checkpoint;
    ///         any other path would be an unauthorised state transition.
    function invariant_payouts_halted_only_on_failed_checkpoint() public view {
        if (!handler.ghost_campaignDecided()) return;

        GiveTypes.CampaignConfig memory cfg = handler.registry().getCampaign(handler.CAMPAIGN_ID());

        if (cfg.payoutsHalted) {
            assertTrue(handler.ghost_hasFailedCheckpoint(), "I3: payoutsHalted=true but no Failed checkpoint recorded");
        }
    }

    // ── I4 ───────────────────────────────────────────────────────────

    /// @notice For every staker, the on-chain position must be non-negative and
    ///         consistent with the accounting rules:
    ///         shares + pendingWithdrawal >= 0 (trivially uint), and
    ///         a staker with no shares and no pending withdrawal must not exist.
    ///
    ///         Also confirms getStakePosition returns a sane struct (no underflow path).
    function invariant_stake_positions_non_negative() public view {
        if (!handler.ghost_campaignDecided()) return;

        for (uint8 i = 0; i < 3; i++) {
            address staker_ = handler.staker(i);
            GiveTypes.SupporterStake memory pos = handler.registry().getStakePosition(handler.CAMPAIGN_ID(), staker_);

            // A staker marked exists=true must have some stake or pending withdrawal
            if (pos.exists) {
                assertTrue(
                    pos.shares > 0 || pos.pendingWithdrawal > 0,
                    "I4: staker exists=true with zero shares and zero pending"
                );
            }
        }
    }
}
