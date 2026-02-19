// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {ForkBase} from "./ForkBase.t.sol";
import {ForkAddresses} from "./ForkAddresses.sol";
import {PTAdapter} from "../../src/adapters/kinds/PTAdapter.sol";

/// @title PTAdapterPendleBlockerForkTest
/// @notice Fork evidence for Phase 5.5 GAP-3:
///         current PTAdapter is simulation/accounting-only and does not integrate Pendle router flows.
contract PTAdapterPendleBlockerForkTest is ForkBase {
    bytes32 internal constant ADAPTER_ID = keccak256("fork.pt.blocker");
    uint256 internal constant INVEST_AMOUNT = 10_000e6; // USDC 10k

    PTAdapter internal adapter;
    IERC20 internal usdc;

    function setUp() public override {
        super.setUp();
        if (!_forkActive) return;

        usdc = IERC20(ForkAddresses.USDC);
        adapter = new PTAdapter(
            ADAPTER_ID,
            ForkAddresses.USDC,
            address(this),
            uint64(block.timestamp),
            uint64(block.timestamp + 180 days)
        );
    }

    function test_pendle_router_is_deployed_on_base() public requiresFork {
        assertGt(ForkAddresses.PENDLE_ROUTER.code.length, 0, "Pendle router missing on fork");
    }

    function test_invest_tracks_deposits_without_router_interaction() public requiresFork {
        deal(ForkAddresses.USDC, address(this), INVEST_AMOUNT);

        uint256 routerUsdcBefore = usdc.balanceOf(ForkAddresses.PENDLE_ROUTER);

        usdc.transfer(address(adapter), INVEST_AMOUNT);
        adapter.invest(INVEST_AMOUNT);

        uint256 routerUsdcAfter = usdc.balanceOf(ForkAddresses.PENDLE_ROUTER);

        assertEq(adapter.deposits(), INVEST_AMOUNT, "PTAdapter should only track deposits");
        assertEq(usdc.balanceOf(address(adapter)), INVEST_AMOUNT, "assets remain on adapter, not Pendle");
        assertEq(routerUsdcAfter, routerUsdcBefore, "router balance changed unexpectedly");
    }

    function test_harvest_is_noop_and_divest_returns_principal() public requiresFork {
        deal(ForkAddresses.USDC, address(this), INVEST_AMOUNT);
        usdc.transfer(address(adapter), INVEST_AMOUNT);
        adapter.invest(INVEST_AMOUNT);

        vm.warp(block.timestamp + 90 days);
        (uint256 profit, uint256 loss) = adapter.harvest();

        assertEq(profit, 0, "PTAdapter harvest should be no-op pre-integration");
        assertEq(loss, 0, "PTAdapter harvest should report zero loss");

        uint256 vaultBefore = usdc.balanceOf(address(this));
        uint256 returned = adapter.divest(INVEST_AMOUNT);

        assertEq(returned, INVEST_AMOUNT, "divest should return tracked principal");
        assertEq(usdc.balanceOf(address(this)) - vaultBefore, INVEST_AMOUNT, "principal not returned to vault caller");
        assertEq(adapter.deposits(), 0, "deposits should be zero after full divest");
    }
}
