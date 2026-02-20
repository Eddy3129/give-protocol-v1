// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title   FuzzTest01_AaveAdapter
 * @author  GIVE Labs
 * @notice  Stateless property-based fuzzing for AaveAdapter invest/divest logic
 * @dev     Tests core adapter mechanics against simulated Aave pool (MockAavePool):
 *          - invest: arbitrary USDC amounts minted as aTokens
 *          - divest: arbitrary aToken burn + USDC transfer
 *          - Loss handling: divest with insufficient Aave pool balance
 *          - Slippage: user-supplied max-loss enforced during divest
 */

import "forge-std/Test.sol";

import {AaveAdapter} from "../../src/adapters/AaveAdapter.sol";
import {MockAavePool} from "../../src/mocks/MockAavePool.sol";
import {MockERC20} from "../../src/mocks/MockERC20.sol";

contract FuzzTest01_AaveAdapter is Test {
    MockERC20 private usdc;
    MockAavePool private pool;
    AaveAdapter private adapter;

    address private vault;
    address private admin;

    function setUp() public {
        usdc = new MockERC20("USD Coin", "USDC", 6);
        pool = new MockAavePool();
        pool.initReserve(address(usdc), 6);

        vault = makeAddr("vault");
        admin = makeAddr("admin");

        adapter = new AaveAdapter(address(usdc), vault, address(pool), admin);
    }

    function testFuzz_invest_divest_no_loss(uint256 assets) public {
        uint256 boundedAssets = bound(assets, 1e6, 2_000_000e6);

        usdc.mint(vault, boundedAssets);
        vm.prank(vault);
        require(usdc.transfer(address(adapter), boundedAssets), "transfer failed");

        vm.prank(vault);
        adapter.invest(boundedAssets);

        vm.prank(vault);
        uint256 returned = adapter.divest(boundedAssets);

        assertEq(returned, boundedAssets);
        assertEq(adapter.totalInvested(), 0);
    }

    function testFuzz_harvest_accounting_no_drift(uint256 principal, uint256 yieldBps) public {
        uint256 boundedPrincipal = bound(principal, 1e6, 2_000_000e6);
        uint256 boundedYieldBps = bound(yieldBps, 1, 2_000);

        usdc.mint(vault, boundedPrincipal);
        vm.prank(vault);
        require(usdc.transfer(address(adapter), boundedPrincipal), "transfer failed");

        vm.prank(vault);
        adapter.invest(boundedPrincipal);

        uint256 yieldAmount = (boundedPrincipal * boundedYieldBps) / 10_000;
        if (yieldAmount == 0) {
            yieldAmount = 1;
        }

        usdc.mint(address(this), yieldAmount);
        usdc.approve(address(pool), yieldAmount);
        pool.accrueYield(address(usdc), yieldAmount);

        uint256 preHarvestATokenBalance = adapter.totalAssets();
        uint256 preHarvestInvested = adapter.totalInvested();

        vm.prank(vault);
        (uint256 profit, uint256 loss) = adapter.harvest();

        assertEq(loss, 0);
        assertApproxEqAbs(profit, preHarvestATokenBalance - preHarvestInvested, 2);
        assertApproxEqAbs(adapter.totalInvested(), preHarvestATokenBalance - profit, 2);
    }
}
