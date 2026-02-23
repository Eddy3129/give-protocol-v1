// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ForkBase} from "./ForkBase.t.sol";
import {ForkAddresses} from "./ForkAddresses.sol";
import {AaveAdapter} from "../../src/adapters/AaveAdapter.sol";
import {GiveErrors} from "../../src/utils/GiveErrors.sol";

/**
 * @title   ForkTest01_AaveAdapter
 * @author  GIVE Labs
 * @notice  Validates AaveAdapter behaviour against live Aave V3 on Base mainnet.
 * @dev     This test contract acts as the vault (has VAULT_ROLE on the adapter).
 *          Tests:
 *          - invest() supplies USDC to Aave, receives aUSDC
 *          - totalAssets() mirrors live aToken balance
 *          - harvest() accrues real yield after vm.warp(30 days)
 *          - divest() returns USDC within slippage tolerance
 *          - emergencyWithdraw() recovers >= 99% principal from live Aave
 *          - isHealthy() reflects live reserve state
 *          - double-harvest drift stays within 1 wei
 *          - emergencyMode blocks new invest() calls after activation
 *          - paused adapter blocks invest/divest/harvest
 */
contract ForkTest01_AaveAdapter is ForkBase {
    AaveAdapter internal adapter;

    address internal admin;
    IERC20 internal usdc;
    IERC20 internal ausdc;

    uint256 internal constant INVEST_AMOUNT = 10_000e6;
    uint256 internal constant MAX_SLIPPAGE_BPS = 100; // 1%

    function setUp() public override {
        super.setUp();
        if (!_forkActive) return;

        admin = makeAddr("adapter_admin");
        usdc = IERC20(ForkAddresses.USDC);
        ausdc = IERC20(ForkAddresses.AUSDC);

        // This test contract IS the vault — it holds VAULT_ROLE on the adapter
        adapter = new AaveAdapter(
            ForkAddresses.USDC,
            address(this), // vault = this
            ForkAddresses.AAVE_POOL,
            admin
        );

        // Seed the adapter's "vault" (this contract) with USDC for invest calls
        _dealUsdc(address(this), 100_000e6);
        usdc.approve(address(adapter), type(uint256).max);
    }

    // ── Helper ────────────────────────────────────────────────────────

    function _invest(uint256 amount) internal {
        usdc.transfer(address(adapter), amount);
        adapter.invest(amount);
    }

    // ── Tests ─────────────────────────────────────────────────────────

    function test_invest_transfers_usdc_to_aave() public requiresFork {
        _invest(INVEST_AMOUNT);
        assertEq(usdc.balanceOf(address(adapter)), 0, "adapter still holds USDC after invest");
        assertGt(ausdc.balanceOf(address(adapter)), 0, "adapter has no aUSDC after invest");
    }

    function test_total_assets_equals_ausdc_balance() public requiresFork {
        _invest(INVEST_AMOUNT);
        assertEq(adapter.totalAssets(), ausdc.balanceOf(address(adapter)), "totalAssets() != aToken balance");
    }

    function test_harvest_accrues_real_yield_after_30_days() public requiresFork {
        _invest(INVEST_AMOUNT);
        uint256 vaultUsdcBefore = usdc.balanceOf(address(this));
        uint256 balanceBefore = ausdc.balanceOf(address(adapter));

        vm.warp(block.timestamp + 30 days);

        (uint256 profit, uint256 loss) = adapter.harvest();

        assertGt(profit, 0, "no yield after 30 days");
        assertEq(loss, 0, "unexpected loss from Aave");
        assertGt(usdc.balanceOf(address(this)), vaultUsdcBefore, "profit not transferred to vault");
        // aToken balance should now equal principal (profit withdrawn)
        assertApproxEqAbs(
            ausdc.balanceOf(address(adapter)),
            balanceBefore,
            1, // dust from rebasing
            "aToken balance inconsistent after harvest"
        );
    }

    function test_divest_returns_usdc_within_slippage() public requiresFork {
        _invest(INVEST_AMOUNT);
        uint256 divestAmount = 5_000e6;

        uint256 balanceBefore = usdc.balanceOf(address(this));
        adapter.divest(divestAmount);
        uint256 received = usdc.balanceOf(address(this)) - balanceBefore;

        uint256 minExpected = divestAmount * (10_000 - MAX_SLIPPAGE_BPS) / 10_000;
        assertGe(received, minExpected, "divest returned less than slippage tolerance");
    }

    function test_divest_full_resets_total_invested() public requiresFork {
        _invest(INVEST_AMOUNT);
        adapter.divest(type(uint256).max);
        assertEq(adapter.totalInvested(), 0, "totalInvested not reset after full divest");
        assertLe(
            ausdc.balanceOf(address(adapter)),
            1, // dust allowance
            "aToken balance not zero after full divest"
        );
    }

    function test_emergency_withdraw_recovers_all_to_vault() public requiresFork {
        _invest(INVEST_AMOUNT);

        uint256 balanceBefore = usdc.balanceOf(address(this));
        adapter.emergencyWithdraw();
        uint256 recovered = usdc.balanceOf(address(this)) - balanceBefore;

        // Should recover at least 99% (5% emergency exit tolerance, but Aave won't lose 1%)
        assertGe(recovered, INVEST_AMOUNT * 99 / 100, "emergency recover below 99%");
        assertEq(adapter.totalInvested(), 0, "totalInvested not reset after emergency");
    }

    function test_is_healthy_on_live_reserve() public requiresFork {
        assertTrue(adapter.isHealthy(), "adapter not healthy on live reserve");
    }

    function test_isHealthy_false_after_emergency_mode_activated() public requiresFork {
        assertTrue(adapter.isHealthy(), "should be healthy before emergency");

        _invest(INVEST_AMOUNT);
        adapter.emergencyWithdraw(); // activates emergencyMode

        assertFalse(adapter.isHealthy(), "should be unhealthy after emergency mode activated");
    }

    function test_invest_reverts_when_emergency_mode_active() public requiresFork {
        _invest(INVEST_AMOUNT);
        adapter.emergencyWithdraw(); // activates emergencyMode

        usdc.transfer(address(adapter), INVEST_AMOUNT);
        vm.expectRevert(GiveErrors.AdapterPaused.selector);
        adapter.invest(INVEST_AMOUNT);
    }

    function test_pause_blocks_invest_divest_harvest() public requiresFork {
        _invest(INVEST_AMOUNT);

        vm.prank(admin);
        adapter.pause();

        // invest blocked
        usdc.transfer(address(adapter), 1_000e6);
        vm.expectRevert();
        adapter.invest(1_000e6);

        // divest blocked
        vm.expectRevert();
        adapter.divest(1_000e6);

        // harvest blocked
        vm.expectRevert();
        adapter.harvest();
    }

    function test_harvest_twice_does_not_drift_total_invested() public requiresFork {
        _invest(INVEST_AMOUNT);
        vm.warp(block.timestamp + 15 days);
        adapter.harvest();

        uint256 investedAfterFirst = adapter.totalInvested();
        uint256 aTokenAfterFirst = ausdc.balanceOf(address(adapter));

        // totalInvested should equal aToken balance after harvest
        assertApproxEqAbs(
            investedAfterFirst, aTokenAfterFirst, 1, "totalInvested drifted from aToken balance after first harvest"
        );

        vm.warp(block.timestamp + 15 days);
        adapter.harvest();

        uint256 investedAfterSecond = adapter.totalInvested();
        uint256 aTokenAfterSecond = ausdc.balanceOf(address(adapter));

        assertApproxEqAbs(
            investedAfterSecond, aTokenAfterSecond, 1, "totalInvested drifted from aToken balance after second harvest"
        );
    }
}
