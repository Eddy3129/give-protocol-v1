// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";

import {VaultHandler} from "./handlers/VaultHandler.sol";

/// @title InvariantVault
/// @notice Verifies core ERC4626 accounting properties of GiveVault4626.
///         No yield adapter is used — all assets remain as vault cash — so
///         the only source of totalAssets increase is explicit injectYield calls.
///
/// Properties tested:
///   I1. totalAssets >= net assets in (deposit + yield - withdraw).
///   I2. convertToAssets(totalSupply) <= totalAssets + 1 (no phantom assets).
///   I3. Sum of all tracked actor share balances == totalSupply (share conservation).
///   I4. previewRedeem(unit) >= unit (share price never falls below initial 1:1 rate).
contract InvariantVault is Test {
    VaultHandler internal handler;

    function setUp() public {
        handler = new VaultHandler();
        targetContract(address(handler));
    }

    // ── I1 ───────────────────────────────────────────────────────────

    /// @notice Vault totalAssets must always equal the net assets flowing in.
    ///         With no adapter, all assets remain as vault cash:
    ///         totalAssets = deposited + yieldInjected - withdrawn (exact).
    function invariant_total_assets_equals_net_flows() public view {
        uint256 netIn = handler.ghost_totalDeposited()
            + handler.ghost_totalYieldInjected()
            - handler.ghost_totalWithdrawn();

        // Allow 1 wei for OZ ERC4626 virtual share rounding
        assertApproxEqAbs(
            handler.vault().totalAssets(),
            netIn,
            1,
            "I1: totalAssets != net asset flows"
        );
    }

    // ── I2 ───────────────────────────────────────────────────────────

    /// @notice convertToAssets(totalSupply) must not exceed totalAssets + 1.
    ///         OZ ERC4626 virtual shares cause floor-rounding, so converted
    ///         is always slightly <= totalAssets. Exceeding it would mean the
    ///         vault is promising more assets than it holds.
    function invariant_erc4626_no_phantom_assets() public view {
        uint256 supply = handler.vault().totalSupply();
        if (supply == 0) return;

        uint256 converted = handler.vault().convertToAssets(supply);
        uint256 actual = handler.vault().totalAssets();

        assertLe(converted, actual + 1, "I2: convertToAssets(totalSupply) > totalAssets + 1");
    }

    // ── I3 ───────────────────────────────────────────────────────────

    /// @notice The sum of all tracked actor balances must equal totalSupply exactly.
    ///         Since the handler only mints shares via deposit/mint and burns via
    ///         withdraw/redeem, no shares can appear outside the tracked set.
    function invariant_share_sum_equals_total_supply() public view {
        uint256 shareSum;
        for (uint8 i = 0; i < uint8(handler.ACTOR_COUNT()); i++) {
            shareSum += handler.vault().balanceOf(handler.actor(i));
        }
        assertEq(shareSum, handler.vault().totalSupply(), "I3: shareSum != totalSupply");
    }

    // ── I4 ───────────────────────────────────────────────────────────

    /// @notice Share price (assets per share) must never fall below the initial 1:1 rate.
    ///         Without a yield adapter there are no losses. Yield injection can only
    ///         increase totalAssets while leaving totalSupply unchanged, so share price
    ///         is non-decreasing.
    ///
    ///         Expressed as: previewRedeem(1 share unit) >= 1 asset unit.
    function invariant_share_price_nondecreasing() public view {
        if (handler.vault().totalSupply() == 0) return;

        // vault.decimals() matches asset decimals (OZ ERC4626, decimalsOffset = 0)
        uint256 unit = 10 ** handler.vault().decimals();
        assertGe(
            handler.vault().previewRedeem(unit),
            unit,
            "I4: share price fell below 1:1"
        );
    }
}
