// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";

import {GrowthAdapter} from "../../src/adapters/kinds/GrowthAdapter.sol";
import {CompoundingAdapter} from "../../src/adapters/kinds/CompoundingAdapter.sol";
import {PTAdapter} from "../../src/adapters/kinds/PTAdapter.sol";
import {ClaimableYieldAdapter} from "../../src/adapters/kinds/ClaimableYieldAdapter.sol";
import {MockERC20} from "../../src/mocks/MockERC20.sol";

contract TestContract11_AdapterKinds is Test {
    MockERC20 public asset;
    address public vault;

    bytes32 public constant ADAPTER_ID = keccak256("UNIT_ADAPTER");

    function setUp() public {
        asset = new MockERC20("Unit Token", "UNIT", 18);
        vault = makeAddr("vault");
        asset.mint(vault, 1_000_000 ether);
    }

    function test_Contract11_Case01_Compounding_investDivestHarvest() public {
        CompoundingAdapter adapter = new CompoundingAdapter(ADAPTER_ID, address(asset), vault);

        vm.prank(vault);
        asset.transfer(address(adapter), 100 ether);

        vm.prank(vault);
        adapter.invest(100 ether);
        assertEq(adapter.investedAmount(), 100 ether);

        asset.mint(address(this), 15 ether);
        asset.approve(address(adapter), 15 ether);
        adapter.addProfit(15 ether);

        vm.prank(vault);
        (uint256 profit, uint256 loss) = adapter.harvest();
        assertEq(profit, 15 ether);
        assertEq(loss, 0);

        vm.prank(vault);
        uint256 returned = adapter.divest(100 ether);
        assertEq(returned, 100 ether);
        assertEq(adapter.investedAmount(), 0);
    }

    function test_Contract11_Case02_Growth_investDivestWithIndexGrowth() public {
        GrowthAdapter adapter = new GrowthAdapter(ADAPTER_ID, address(asset), vault);

        asset.mint(address(adapter), 120 ether);
        vm.prank(vault);
        adapter.invest(100 ether);

        adapter.setGrowthIndex(1.2e18);
        assertEq(adapter.totalAssets(), 120 ether);

        vm.prank(vault);
        uint256 returned = adapter.divest(120 ether);
        assertEq(returned, 120 ether);
        assertEq(adapter.totalDeposits(), 0);
    }

    function test_Contract11_Case03_ClaimableYield_investQueueHarvest() public {
        ClaimableYieldAdapter adapter = new ClaimableYieldAdapter(ADAPTER_ID, address(asset), vault);

        vm.prank(vault);
        asset.transfer(address(adapter), 100 ether);

        vm.prank(vault);
        adapter.invest(100 ether);
        assertEq(adapter.investedAmount(), 100 ether);

        asset.mint(address(this), 8 ether);
        asset.approve(address(adapter), 8 ether);
        adapter.queueYield(8 ether);

        vm.prank(vault);
        (uint256 profit, uint256 loss) = adapter.harvest();
        assertEq(profit, 8 ether);
        assertEq(loss, 0);
        assertEq(adapter.queuedYield(), 0);
    }

    function test_Contract11_Case04_PT_investDivestAndRollover() public {
        uint64 start = uint64(block.timestamp);
        uint64 maturity = uint64(block.timestamp + 30 days);
        PTAdapter adapter = new PTAdapter(ADAPTER_ID, address(asset), vault, start, maturity);

        vm.prank(vault);
        asset.transfer(address(adapter), 100 ether);

        vm.prank(vault);
        adapter.invest(100 ether);
        assertEq(adapter.deposits(), 100 ether);

        vm.prank(vault);
        uint256 returned = adapter.divest(100 ether);
        assertEq(returned, 100 ether);
        assertEq(adapter.deposits(), 0);

        uint64 newStart = uint64(block.timestamp + 31 days);
        uint64 newMaturity = uint64(block.timestamp + 61 days);
        vm.prank(vault);
        adapter.rollover(newStart, newMaturity);

        (uint64 currentStart, uint64 currentMaturity) = adapter.currentSeries();
        assertEq(currentStart, newStart);
        assertEq(currentMaturity, newMaturity);
    }
}
