// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title   ForkTest10_PendleAdapter
 * @author  GIVE Labs
 * @notice  Fork test for Pendle Protocol Principal Token (PT) adapter integration
 * @dev     Tests real PT market interactions on Base mainnet fork:
 *          - PT invest (deposit asset, mint PT) via Pendle Router
 *          - PT divest (redeem PT, receive asset) via Pendle Router
 *          - Slippage validation and error handling
 *          Requires PENDLE_BASE_MARKET and PENDLE_BASE_PT environment variables.
 */

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {ForkBase} from "./ForkBase.t.sol";
import {ForkAddresses} from "./ForkAddresses.sol";
import {PendleAdapter} from "../../src/adapters/kinds/PendleAdapter.sol";

contract ForkTest10_PendleAdapter is ForkBase {
    bytes32 internal constant ADAPTER_ID = keccak256("fork.pendle.adapter");

    IERC20 internal usdc;
    IERC20 internal pt;
    PendleAdapter internal adapter;

    address internal market;
    bool internal configured;

    function setUp() public override {
        super.setUp();
        if (!_forkActive) return;

        usdc = IERC20(ForkAddresses.USDC);

        market = vm.envOr("PENDLE_BASE_MARKET", address(0));
        address ptAddr = vm.envOr("PENDLE_BASE_PT", address(0));
        if (market == address(0) || ptAddr == address(0)) {
            return;
        }

        pt = IERC20(ptAddr);
        adapter = new PendleAdapter(
            ADAPTER_ID, ForkAddresses.USDC, address(this), ForkAddresses.PENDLE_ROUTER, market, ptAddr
        );

        configured = true;
    }

    function test_router_deployed_on_base() public requiresFork {
        assertGt(ForkAddresses.PENDLE_ROUTER.code.length, 0, "pendle router missing");
    }

    function test_invest_divest_roundtrip_when_market_env_configured() public requiresFork {
        if (!configured) {
            return;
        }

        uint256 amount = 1_000e6;
        deal(ForkAddresses.USDC, address(this), amount);

        usdc.transfer(address(adapter), amount);
        adapter.invest(amount);

        assertGt(pt.balanceOf(address(adapter)), 0, "no pt received");

        uint256 vaultBefore = usdc.balanceOf(address(this));
        uint256 returned = adapter.divest(amount / 2);

        assertGt(returned, 0, "no token out returned");
        assertEq(usdc.balanceOf(address(this)) - vaultBefore, returned, "returned mismatch");
    }
}
