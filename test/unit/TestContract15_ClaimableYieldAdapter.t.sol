// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";

import {ClaimableYieldAdapter} from "../../src/adapters/kinds/ClaimableYieldAdapter.sol";
import {MockERC20} from "../../src/mocks/MockERC20.sol";
import {GiveErrors} from "../../src/utils/GiveErrors.sol";

contract TestContract15_ClaimableYieldAdapter is Test {
    MockERC20 public asset;
    address public vault;
    ClaimableYieldAdapter public adapter;

    bytes32 public constant ADAPTER_ID = keccak256("UNIT_CLAIMABLE");

    function setUp() public {
        asset = new MockERC20("Unit Token", "UNIT", 18);
        vault = makeAddr("vault");
        adapter = new ClaimableYieldAdapter(ADAPTER_ID, address(asset), vault);

        asset.mint(vault, 1_000_000 ether);
        asset.mint(address(this), 100_000 ether);
    }

    // ─── invest ──────────────────────────────────────────────────────────────

    function test_Contract15_Case01_invest_tracksPrincipal() public {
        vm.prank(vault);
        asset.transfer(address(adapter), 100 ether);
        vm.prank(vault);
        adapter.invest(100 ether);

        assertEq(adapter.investedAmount(), 100 ether);
        // totalAssets() returns only principal, not queued yield
        assertEq(adapter.totalAssets(), 100 ether);
    }

    function test_Contract15_Case02_invest_zeroReverts() public {
        vm.prank(vault);
        vm.expectRevert(GiveErrors.InvalidInvestAmount.selector);
        adapter.invest(0);
    }

    function test_Contract15_Case03_invest_onlyVault() public {
        vm.prank(makeAddr("rando"));
        vm.expectRevert(GiveErrors.OnlyVault.selector);
        adapter.invest(1 ether);
    }

    // ─── divest ──────────────────────────────────────────────────────────────

    function test_Contract15_Case04_divest_partial() public {
        vm.startPrank(vault);
        asset.transfer(address(adapter), 100 ether);
        adapter.invest(100 ether);

        uint256 vaultBefore = asset.balanceOf(vault);
        uint256 returned = adapter.divest(40 ether);
        vm.stopPrank();

        assertEq(returned, 40 ether);
        assertEq(adapter.investedAmount(), 60 ether);
        assertEq(asset.balanceOf(vault) - vaultBefore, 40 ether);
    }

    function test_Contract15_Case05_divest_cappedAtInvestedAmount() public {
        vm.startPrank(vault);
        asset.transfer(address(adapter), 100 ether);
        adapter.invest(100 ether);

        // Request more than invested — should cap and return full invested
        uint256 returned = adapter.divest(150 ether);
        vm.stopPrank();

        assertEq(returned, 100 ether, "should cap at investedAmount");
        assertEq(adapter.investedAmount(), 0);
    }

    function test_Contract15_Case06_divest_zeroReverts() public {
        vm.prank(vault);
        vm.expectRevert(GiveErrors.InvalidDivestAmount.selector);
        adapter.divest(0);
    }

    function test_Contract15_Case07_divest_onlyVault() public {
        vm.prank(makeAddr("rando"));
        vm.expectRevert(GiveErrors.OnlyVault.selector);
        adapter.divest(1 ether);
    }

    // ─── harvest ─────────────────────────────────────────────────────────────

    function test_Contract15_Case08_harvest_withQueuedYield() public {
        vm.startPrank(vault);
        asset.transfer(address(adapter), 100 ether);
        adapter.invest(100 ether);
        vm.stopPrank();

        // Queue 8 ether of yield
        asset.approve(address(adapter), 8 ether);
        adapter.queueYield(8 ether);
        assertEq(adapter.queuedYield(), 8 ether);

        uint256 vaultBefore = asset.balanceOf(vault);
        vm.prank(vault);
        (uint256 profit, uint256 loss) = adapter.harvest();

        assertEq(profit, 8 ether);
        assertEq(loss, 0);
        assertEq(adapter.queuedYield(), 0, "queue should be cleared");
        assertEq(asset.balanceOf(vault) - vaultBefore, 8 ether);
        // Principal unchanged
        assertEq(adapter.investedAmount(), 100 ether);
    }

    function test_Contract15_Case09_harvest_zeroQueuedYieldNoOp() public {
        vm.prank(vault);
        asset.transfer(address(adapter), 50 ether);
        vm.prank(vault);
        adapter.invest(50 ether);

        uint256 vaultBefore = asset.balanceOf(vault);
        vm.prank(vault);
        (uint256 profit, uint256 loss) = adapter.harvest();

        assertEq(profit, 0);
        assertEq(loss, 0);
        assertEq(asset.balanceOf(vault), vaultBefore, "vault balance should not change");
    }

    function test_Contract15_Case10_harvest_onlyVault() public {
        vm.prank(makeAddr("rando"));
        vm.expectRevert(GiveErrors.OnlyVault.selector);
        adapter.harvest();
    }

    // ─── emergencyWithdraw ────────────────────────────────────────────────────

    function test_Contract15_Case11_emergencyWithdraw_includesPrincipalAndYield() public {
        vm.startPrank(vault);
        asset.transfer(address(adapter), 100 ether);
        adapter.invest(100 ether);
        vm.stopPrank();

        asset.approve(address(adapter), 5 ether);
        adapter.queueYield(5 ether);

        uint256 vaultBefore = asset.balanceOf(vault);
        vm.prank(vault);
        uint256 returned = adapter.emergencyWithdraw();

        assertEq(returned, 105 ether);
        assertEq(asset.balanceOf(vault) - vaultBefore, 105 ether);
        assertEq(adapter.investedAmount(), 0);
        assertEq(adapter.queuedYield(), 0);
    }

    function test_Contract15_Case12_emergencyWithdraw_onlyVault() public {
        vm.prank(makeAddr("rando"));
        vm.expectRevert(GiveErrors.OnlyVault.selector);
        adapter.emergencyWithdraw();
    }

    // ─── queueYield ──────────────────────────────────────────────────────────

    function test_Contract15_Case13_queueYield_pullsTokensAndAccumulates() public {
        asset.approve(address(adapter), 20 ether);
        adapter.queueYield(12 ether);
        adapter.queueYield(8 ether);

        assertEq(adapter.queuedYield(), 20 ether);
        assertEq(asset.balanceOf(address(adapter)), 20 ether);
    }
}
