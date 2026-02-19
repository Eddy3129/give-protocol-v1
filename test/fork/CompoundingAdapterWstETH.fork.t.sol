// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {ForkBase} from "./ForkBase.t.sol";
import {ForkAddresses} from "./ForkAddresses.sol";
import {CompoundingAdapter} from "../../src/adapters/kinds/CompoundingAdapter.sol";

/// @title CompoundingAdapterWstETHForkTest
/// @notice Fork coverage for Phase 5.5 GAP-2 using live Base wstETH token.
///         This suite validates the adapter's current token-count accounting model.
contract CompoundingAdapterWstETHForkTest is ForkBase {
    bytes32 internal constant ADAPTER_ID = keccak256("fork.wsteth.compounding");
    uint256 internal constant INVEST_AMOUNT = 10 ether;

    CompoundingAdapter internal adapter;
    IERC20 internal wsteth;

    function setUp() public override {
        super.setUp();
        if (!_forkActive) return;

        wsteth = IERC20(ForkAddresses.WSTETH);
        adapter = new CompoundingAdapter(ADAPTER_ID, ForkAddresses.WSTETH, address(this));
    }

    function test_invest_holds_wsteth() public requiresFork {
        deal(ForkAddresses.WSTETH, address(this), INVEST_AMOUNT);

        wsteth.transfer(address(adapter), INVEST_AMOUNT);
        adapter.invest(INVEST_AMOUNT);

        assertEq(wsteth.balanceOf(address(adapter)), INVEST_AMOUNT, "adapter should hold invested wstETH");
        assertEq(adapter.investedAmount(), INVEST_AMOUNT, "investedAmount should track principal");
    }

    function test_harvest_after_timewarp_is_zero_without_balance_growth() public requiresFork {
        deal(ForkAddresses.WSTETH, address(this), INVEST_AMOUNT);
        wsteth.transfer(address(adapter), INVEST_AMOUNT);
        adapter.invest(INVEST_AMOUNT);

        uint256 vaultBalanceBefore = wsteth.balanceOf(address(this));
        vm.warp(block.timestamp + 365 days);

        (uint256 profit, uint256 loss) = adapter.harvest();

        assertEq(profit, 0, "no profit expected without token-balance increase");
        assertEq(loss, 0, "compounding adapter should not report loss here");
        assertEq(wsteth.balanceOf(address(this)), vaultBalanceBefore, "vault should not receive tokens on zero-profit harvest");
    }

    function test_harvest_transfers_profit_when_adapter_balance_increases() public requiresFork {
        deal(ForkAddresses.WSTETH, address(this), INVEST_AMOUNT + 1 ether);

        wsteth.transfer(address(adapter), INVEST_AMOUNT);
        adapter.invest(INVEST_AMOUNT);

        uint256 balanceBefore = wsteth.balanceOf(address(adapter));
        deal(ForkAddresses.WSTETH, address(adapter), balanceBefore + 1 ether);

        uint256 vaultBalanceBefore = wsteth.balanceOf(address(this));
        (uint256 profit, uint256 loss) = adapter.harvest();

        assertEq(profit, 1 ether, "harvested profit should match excess token balance");
        assertEq(loss, 0, "loss should remain zero");
        assertEq(wsteth.balanceOf(address(this)) - vaultBalanceBefore, 1 ether, "vault should receive harvested profit");
        assertEq(adapter.investedAmount(), INVEST_AMOUNT, "principal tracking should remain unchanged after harvest");
    }

    function test_full_cycle_invest_divest_roundtrip() public requiresFork {
        deal(ForkAddresses.WSTETH, address(this), INVEST_AMOUNT);

        wsteth.transfer(address(adapter), INVEST_AMOUNT);
        adapter.invest(INVEST_AMOUNT);

        uint256 vaultBefore = wsteth.balanceOf(address(this));
        uint256 returned = adapter.divest(INVEST_AMOUNT);

        assertEq(returned, INVEST_AMOUNT, "divest should return requested principal");
        assertEq(wsteth.balanceOf(address(this)) - vaultBefore, INVEST_AMOUNT, "vault should recover principal");
        assertEq(adapter.investedAmount(), 0, "investedAmount should reset after full divest");
        assertEq(wsteth.balanceOf(address(adapter)), 0, "adapter should not retain principal after full divest");
    }
}
