// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";

import {PayoutRouterHandler} from "./handlers/PayoutRouterHandler.sol";

/// @title InvariantPayoutRouter
/// @notice Verifies core safety properties of the PayoutRouter accumulator model.
///
/// Properties tested:
///   I1. No yield is created from thin air — claimed <= recorded at all times.
///   I2. Router token balance always covers undistributed yield.
///   I3. Protocol fees are bounded by MAX_FEE_BPS of total recorded yield.
///   I4. The per-share accumulator is monotonically non-decreasing.
///   I5. Pending yield across all actors cannot exceed recorded minus claimed.
contract InvariantPayoutRouter is Test {
    PayoutRouterHandler internal handler;

    function setUp() public {
        handler = new PayoutRouterHandler();
        targetContract(address(handler));
    }

    // ── I1 ───────────────────────────────────────────────────────────

    /// @notice Total yield claimed by all actors must never exceed total yield recorded.
    ///         Violated if claimYield pays out more tokens than were deposited via recordYield.
    function invariant_claimed_never_exceeds_recorded() public view {
        assertLe(
            handler.ghost_totalClaimed(),
            handler.ghost_totalRecorded(),
            "I1: claimed > recorded"
        );
    }

    // ── I2 ───────────────────────────────────────────────────────────

    /// @notice The router's token balance must cover the undistributed portion of recorded yield.
    ///         (recorded - claimed) tokens must remain in the router until users claim them.
    ///         Violated if tokens are leaked to addresses other than legitimate claimants.
    function invariant_router_balance_covers_undistributed() public view {
        uint256 recorded = handler.ghost_totalRecorded();
        uint256 claimed = handler.ghost_totalClaimed();
        uint256 undistributed = recorded >= claimed ? recorded - claimed : 0;
        assertGe(
            handler.routerBalance(),
            undistributed,
            "I2: router balance < undistributed yield"
        );
    }

    // ── I3 ───────────────────────────────────────────────────────────

    /// @notice Protocol fees collected must not exceed MAX_FEE_BPS of total yield recorded.
    ///         Violated if the fee calculation overcharges users.
    function invariant_fee_bounded() public view {
        (, uint256 protocolFees) = handler.router().getCampaignTotals(handler.CAMPAIGN_ID());
        uint256 ceiling = (handler.ghost_totalRecorded() * handler.MAX_FEE_BPS()) / 10_000;
        assertLe(protocolFees, ceiling, "I3: protocolFees > MAX_FEE_BPS ceiling");
    }

    // ── I4 ───────────────────────────────────────────────────────────

    /// @notice The per-share yield accumulator must never decrease.
    ///         Tracked by the handler flag set whenever pending yield for a non-zero-share
    ///         actor decreases between recordYield or updateUserShares calls.
    function invariant_accumulator_monotonic() public view {
        assertFalse(handler.ghost_accumulatorDecreased(), "I4: accumulator decreased");
    }

    // ── I5 ───────────────────────────────────────────────────────────

    /// @notice Sum of all actors' pending (unclaimed) yield plus total claimed must not
    ///         exceed total recorded yield by more than 1 wei per actor (rounding dust).
    ///         Violated if users can claim yield that was never deposited.
    function invariant_pending_bounded_by_recorded() public view {
        uint256 totalPending;
        for (uint8 i = 0; i < 3; i++) {
            totalPending += handler.router().getPendingYield(
                handler.actor(i),
                address(handler),   // handler IS the vault
                address(handler.asset())
            );
        }
        // Allow 1 wei rounding dust per actor (integer division in accumulator math)
        uint256 dust = 3;
        assertLe(
            totalPending + handler.ghost_totalClaimed(),
            handler.ghost_totalRecorded() + dust,
            "I5: pending + claimed > recorded (beyond rounding)"
        );
    }
}
