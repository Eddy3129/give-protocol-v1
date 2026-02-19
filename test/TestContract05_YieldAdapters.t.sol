// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";

import "../src/adapters/kinds/GrowthAdapter.sol";
import "../src/adapters/kinds/CompoundingAdapter.sol";
import "../src/adapters/kinds/PTAdapter.sol";
import "../src/adapters/kinds/ClaimableYieldAdapter.sol";
import "../src/adapters/kinds/ManualManageAdapter.sol";
import "../src/mocks/MockYieldAdapter.sol";
import "../src/mocks/MockERC20.sol";

/**
 * @title TestContract05_YieldAdapters
 * @notice Comprehensive test suite for all yield adapter implementations
 */
contract TestContract05_YieldAdapters is Test {
    MockERC20 public asset;
    address public vault;
    address public admin;
    address public yieldManager;

    bytes32 public constant ADAPTER_ID = keccak256("TEST_ADAPTER");

    function setUp() public {
        asset = new MockERC20("Test Token", "TEST", 18);
        vault = makeAddr("vault");
        admin = makeAddr("admin");
        yieldManager = makeAddr("yieldManager");

        // Fund vault with test tokens
        asset.mint(vault, 1000000 ether);
    }

    // ============================================
    // GROWTH ADAPTER TESTS
    // ============================================

    function test_Contract05_Case01_GrowthAdapter_deploymentState() public {
        GrowthAdapter adapter = new GrowthAdapter(ADAPTER_ID, address(asset), vault);

        assertEq(adapter.adapterId(), ADAPTER_ID);
        assertEq(address(adapter.asset()), address(asset));
        assertEq(adapter.vault(), vault);
        assertEq(adapter.totalDeposits(), 0);
        assertEq(adapter.growthIndex(), 1e18);
    }

    function test_Contract05_Case02_GrowthAdapter_investAndTotalAssets() public {
        GrowthAdapter adapter = new GrowthAdapter(ADAPTER_ID, address(asset), vault);

        vm.startPrank(vault);
        adapter.invest(100 ether);
        vm.stopPrank();

        assertEq(adapter.totalDeposits(), 100 ether);
        assertEq(adapter.totalAssets(), 100 ether); // 100 * 1e18 / 1e18
    }

    function test_Contract05_Case03_GrowthAdapter_growthIndexIncrease() public {
        GrowthAdapter adapter = new GrowthAdapter(ADAPTER_ID, address(asset), vault);

        vm.prank(vault);
        adapter.invest(100 ether);

        // Simulate 10% growth
        adapter.setGrowthIndex(1.1e18);

        assertEq(adapter.totalAssets(), 110 ether); // 100 * 1.1e18 / 1e18
    }

    function test_Contract05_Case04_GrowthAdapter_divestAfterGrowth() public {
        GrowthAdapter adapter = new GrowthAdapter(ADAPTER_ID, address(asset), vault);

        // Fund adapter
        asset.mint(address(adapter), 110 ether);

        vm.prank(vault);
        adapter.invest(100 ether);

        adapter.setGrowthIndex(1.1e18);

        vm.prank(vault);
        uint256 returned = adapter.divest(110 ether);

        assertEq(returned, 110 ether);
        assertEq(adapter.totalDeposits(), 0);
    }

    // ============================================
    // COMPOUNDING ADAPTER TESTS
    // ============================================

    function test_Contract05_Case05_CompoundingAdapter_investAndDivest() public {
        CompoundingAdapter adapter = new CompoundingAdapter(ADAPTER_ID, address(asset), vault);

        // Transfer to adapter then invest
        vm.prank(vault);
        require(asset.transfer(address(adapter), 100 ether), "Transfer failed");

        vm.prank(vault);
        adapter.invest(100 ether);

        assertEq(adapter.investedAmount(), 100 ether);
        assertEq(adapter.totalAssets(), 100 ether);

        vm.prank(vault);
        adapter.divest(50 ether);

        assertEq(adapter.investedAmount(), 50 ether);
    }

    function test_Contract05_Case06_CompoundingAdapter_harvestProfit() public {
        CompoundingAdapter adapter = new CompoundingAdapter(ADAPTER_ID, address(asset), vault);

        // Transfer and invest
        vm.prank(vault);
        require(asset.transfer(address(adapter), 100 ether), "Transfer failed");

        vm.prank(vault);
        adapter.invest(100 ether);

        // Add profit
        asset.mint(address(this), 10 ether);
        asset.approve(address(adapter), 10 ether);
        adapter.addProfit(10 ether);

        uint256 vaultBalanceBefore = asset.balanceOf(vault);

        vm.prank(vault);
        (uint256 profit, uint256 loss) = adapter.harvest();

        assertEq(profit, 10 ether);
        assertEq(loss, 0);
        assertEq(asset.balanceOf(vault), vaultBalanceBefore + 10 ether);
    }

    // ============================================
    // PT ADAPTER TESTS
    // ============================================

    function test_Contract05_Case07_PTAdapter_seriesManagement() public {
        uint64 start = uint64(block.timestamp);
        uint64 maturity = uint64(block.timestamp + 30 days);

        PTAdapter adapter = new PTAdapter(ADAPTER_ID, address(asset), vault, start, maturity);

        (uint64 currentStart, uint64 currentMaturity) = adapter.currentSeries();
        assertEq(currentStart, start);
        assertEq(currentMaturity, maturity);
    }

    function test_Contract05_Case08_PTAdapter_rollover() public {
        uint64 start = uint64(block.timestamp);
        uint64 maturity = uint64(block.timestamp + 30 days);

        PTAdapter adapter = new PTAdapter(ADAPTER_ID, address(asset), vault, start, maturity);

        uint64 newStart = uint64(block.timestamp + 30 days);
        uint64 newMaturity = uint64(block.timestamp + 60 days);

        vm.prank(vault);
        adapter.rollover(newStart, newMaturity);

        (uint64 currentStart, uint64 currentMaturity) = adapter.currentSeries();
        assertEq(currentStart, newStart);
        assertEq(currentMaturity, newMaturity);
    }

    function test_Contract05_Case09_PTAdapter_investAndDivest() public {
        PTAdapter adapter = new PTAdapter(
            ADAPTER_ID, address(asset), vault, uint64(block.timestamp), uint64(block.timestamp + 30 days)
        );

        // Transfer tokens to adapter
        vm.prank(vault);
        require(asset.transfer(address(adapter), 100 ether), "Transfer failed");

        vm.prank(vault);
        adapter.invest(100 ether);

        assertEq(adapter.deposits(), 100 ether);

        vm.prank(vault);
        uint256 returned = adapter.divest(100 ether);

        assertEq(returned, 100 ether);
        assertEq(adapter.deposits(), 0);
    }

    function test_Contract05_Case09b_PTAdapter_invalidSeriesReverts() public {
        vm.expectRevert(abi.encodeWithSelector(PTAdapter.InvalidSeriesWindow.selector, uint64(block.timestamp), uint64(block.timestamp)));
        new PTAdapter(ADAPTER_ID, address(asset), vault, uint64(block.timestamp), uint64(block.timestamp));
    }

    function test_Contract05_Case09c_PTAdapter_emergencyWithdrawTransfersToVault() public {
        PTAdapter adapter = new PTAdapter(
            ADAPTER_ID, address(asset), vault, uint64(block.timestamp), uint64(block.timestamp + 30 days)
        );

        vm.prank(vault);
        require(asset.transfer(address(adapter), 100 ether), "Transfer failed");

        vm.prank(vault);
        adapter.invest(100 ether);

        uint256 vaultBalanceBefore = asset.balanceOf(vault);

        vm.prank(vault);
        uint256 returned = adapter.emergencyWithdraw();

        assertEq(returned, 100 ether);
        assertEq(asset.balanceOf(vault), vaultBalanceBefore + 100 ether);
        assertEq(adapter.deposits(), 0);
    }

    // ============================================
    // CLAIMABLE YIELD ADAPTER TESTS
    // ============================================

    function test_Contract05_Case10_ClaimableYield_investAndQueueYield() public {
        ClaimableYieldAdapter adapter = new ClaimableYieldAdapter(ADAPTER_ID, address(asset), vault);

        // Transfer and invest
        vm.prank(vault);
        require(asset.transfer(address(adapter), 100 ether), "Transfer failed");

        vm.prank(vault);
        adapter.invest(100 ether);

        assertEq(adapter.investedAmount(), 100 ether);
        assertEq(adapter.queuedYield(), 0);

        // Queue yield
        asset.mint(address(this), 10 ether);
        asset.approve(address(adapter), 10 ether);
        adapter.queueYield(10 ether);

        assertEq(adapter.queuedYield(), 10 ether);
    }

    function test_Contract05_Case11_ClaimableYield_harvestQueuedYield() public {
        ClaimableYieldAdapter adapter = new ClaimableYieldAdapter(ADAPTER_ID, address(asset), vault);

        // Invest
        vm.prank(vault);
        require(asset.transfer(address(adapter), 100 ether), "Transfer failed");

        vm.prank(vault);
        adapter.invest(100 ether);

        // Queue yield
        asset.mint(address(this), 10 ether);
        asset.approve(address(adapter), 10 ether);
        adapter.queueYield(10 ether);

        uint256 vaultBalanceBefore = asset.balanceOf(vault);

        vm.prank(vault);
        (uint256 profit, uint256 loss) = adapter.harvest();

        assertEq(profit, 10 ether);
        assertEq(loss, 0);
        assertEq(adapter.queuedYield(), 0);
        assertEq(asset.balanceOf(vault), vaultBalanceBefore + 10 ether);
    }

    // ============================================
    // MANUAL MANAGE ADAPTER TESTS
    // ============================================

    function test_Contract05_Case12_ManualManage_deploymentState() public {
        ManualManageAdapter adapter = new ManualManageAdapter(
            ADAPTER_ID,
            address(asset),
            vault,
            admin,
            yieldManager,
            10 ether // buffer
        );

        assertEq(adapter.investedAmount(), 0);
        assertEq(adapter.managedBalance(), 0);
        assertEq(adapter.bufferAmount(), 10 ether);
        assertEq(adapter.offChainAmount(), 0);
        assertTrue(adapter.hasRole(adapter.YIELD_MANAGER_ROLE(), yieldManager));
    }

    function test_Contract05_Case13_ManualManage_investAndWithdraw() public {
        ManualManageAdapter adapter =
            new ManualManageAdapter(ADAPTER_ID, address(asset), vault, admin, yieldManager, 10 ether);

        // Transfer and invest
        vm.prank(vault);
        require(asset.transfer(address(adapter), 100 ether), "Transfer failed");

        vm.prank(vault);
        adapter.invest(100 ether);

        assertEq(adapter.investedAmount(), 100 ether);
        assertEq(adapter.managedBalance(), 100 ether);

        // Manager withdraws (leaving buffer)
        vm.prank(yieldManager);
        adapter.managerWithdraw(90 ether, yieldManager);

        assertEq(adapter.offChainAmount(), 90 ether);
        assertEq(asset.balanceOf(yieldManager), 90 ether);
        assertEq(asset.balanceOf(address(adapter)), 10 ether); // buffer remains
    }

    function test_Contract05_Case14_ManualManage_updateBalanceAndHarvest() public {
        ManualManageAdapter adapter =
            new ManualManageAdapter(ADAPTER_ID, address(asset), vault, admin, yieldManager, 10 ether);

        // Invest
        vm.prank(vault);
        require(asset.transfer(address(adapter), 100 ether), "Transfer failed");

        vm.prank(vault);
        adapter.invest(100 ether);

        // Manager updates balance to reflect profit
        vm.prank(yieldManager);
        adapter.updateManagedBalance(110 ether);

        assertEq(adapter.managedBalance(), 110 ether);

        // Manager deposits profit
        asset.mint(yieldManager, 10 ether);
        vm.startPrank(yieldManager);
        asset.approve(address(adapter), 10 ether);
        adapter.managerDeposit(10 ether);
        vm.stopPrank();

        // Harvest profit
        uint256 vaultBalanceBefore = asset.balanceOf(vault);

        vm.prank(vault);
        (uint256 profit, uint256 loss) = adapter.harvest();

        assertEq(profit, 10 ether);
        assertEq(loss, 0);
        assertEq(asset.balanceOf(vault), vaultBalanceBefore + 10 ether);
    }

    function test_Contract05_Case15_ManualManage_bufferEnforcement() public {
        ManualManageAdapter adapter =
            new ManualManageAdapter(ADAPTER_ID, address(asset), vault, admin, yieldManager, 10 ether);

        // Invest
        vm.prank(vault);
        require(asset.transfer(address(adapter), 100 ether), "Transfer failed");

        vm.prank(vault);
        adapter.invest(100 ether);

        // Try to withdraw too much (would violate buffer)
        vm.prank(yieldManager);
        vm.expectRevert();
        adapter.managerWithdraw(95 ether, yieldManager); // Would leave only 5 ether buffer
    }

    // ============================================
    // MOCK YIELD ADAPTER TESTS
    // ============================================

    function test_Contract05_Case16_MockYield_yieldGeneration() public {
        MockYieldAdapter adapter = new MockYieldAdapter(address(asset), vault, admin);

        // Invest
        vm.prank(vault);
        require(asset.transfer(address(adapter), 100 ether), "Transfer failed");

        vm.prank(vault);
        adapter.invest(100 ether);

        // Add yield
        asset.mint(admin, 10 ether);
        vm.startPrank(admin);
        asset.approve(address(adapter), 10 ether);
        adapter.addYield(10 ether);
        vm.stopPrank();

        uint256 vaultBalanceBefore = asset.balanceOf(vault);

        vm.prank(vault);
        (uint256 profit, uint256 loss) = adapter.harvest();

        assertEq(profit, 10 ether);
        assertEq(loss, 0);
        assertEq(asset.balanceOf(vault), vaultBalanceBefore + 10 ether);
    }

    function test_Contract05_Case17_MockYield_lossSimulation() public {
        MockYieldAdapter adapter = new MockYieldAdapter(address(asset), vault, admin);

        // Invest
        vm.prank(vault);
        require(asset.transfer(address(adapter), 100 ether), "Transfer failed");

        vm.prank(vault);
        adapter.invest(100 ether);

        // Enable loss simulation (5% loss)
        vm.prank(admin);
        adapter.setLossSimulation(true, 500);

        vm.prank(vault);
        (uint256 profit, uint256 loss) = adapter.harvest();

        assertEq(profit, 0);
        assertEq(loss, 5 ether); // 5% of 100 ether
    }

    // ============================================
    // ACCESS CONTROL TESTS
    // ============================================

    function test_Contract05_Case18_onlyVault_enforcement() public {
        GrowthAdapter adapter = new GrowthAdapter(ADAPTER_ID, address(asset), vault);

        vm.expectRevert();
        adapter.invest(100 ether); // Called by test contract, not vault

        vm.expectRevert();
        adapter.divest(100 ether);

        vm.expectRevert();
        adapter.harvest();

        vm.expectRevert();
        adapter.emergencyWithdraw();
    }

    // ============================================
    // EMERGENCY WITHDRAW TESTS
    // ============================================

    function test_Contract05_Case19_emergencyWithdraw_allAdapters() public {
        // Test GrowthAdapter
        GrowthAdapter growth = new GrowthAdapter(ADAPTER_ID, address(asset), vault);
        asset.mint(address(growth), 100 ether);
        vm.prank(vault);
        growth.invest(100 ether);

        vm.prank(vault);
        uint256 returned = growth.emergencyWithdraw();
        assertEq(returned, 100 ether);
        assertEq(growth.totalDeposits(), 0);

        // Test CompoundingAdapter
        CompoundingAdapter compounding = new CompoundingAdapter(ADAPTER_ID, address(asset), vault);
        asset.mint(address(compounding), 100 ether);
        vm.prank(vault);
        compounding.invest(100 ether);

        vm.prank(vault);
        returned = compounding.emergencyWithdraw();
        assertEq(returned, 100 ether);
        assertEq(compounding.investedAmount(), 0);
    }
}
