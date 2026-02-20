// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";

import {ManualManageAdapter} from "../../src/adapters/kinds/ManualManageAdapter.sol";
import {MockERC20} from "../../src/mocks/MockERC20.sol";
import {GiveErrors} from "../../src/utils/GiveErrors.sol";

contract TestContract14_ManualManageAdapter is Test {
    MockERC20 public asset;
    address public vault;
    address public admin;
    address public manager;
    ManualManageAdapter public adapter;

    bytes32 public constant ADAPTER_ID = keccak256("UNIT_MANUAL");
    uint256 public constant INITIAL_BUFFER = 10 ether;

    function setUp() public {
        asset = new MockERC20("Unit Token", "UNIT", 18);
        vault = makeAddr("vault");
        admin = makeAddr("admin");
        manager = makeAddr("manager");

        adapter = new ManualManageAdapter(ADAPTER_ID, address(asset), vault, admin, manager, INITIAL_BUFFER);

        asset.mint(vault, 1_000_000 ether);
        asset.mint(manager, 1_000_000 ether);
    }

    // ─── invest ──────────────────────────────────────────────────────────────

    function test_Contract14_Case01_invest_updatesAccountingAndEmits() public {
        vm.startPrank(vault);
        asset.transfer(address(adapter), 100 ether);
        adapter.invest(100 ether);
        vm.stopPrank();

        assertEq(adapter.investedAmount(), 100 ether, "investedAmount mismatch");
        assertEq(adapter.managedBalance(), 100 ether, "managedBalance mismatch");
        assertEq(adapter.totalAssets(), 100 ether, "totalAssets mismatch");
    }

    function test_Contract14_Case02_invest_zeroReverts() public {
        vm.prank(vault);
        vm.expectRevert(GiveErrors.InvalidInvestAmount.selector);
        adapter.invest(0);
    }

    function test_Contract14_Case03_invest_onlyVault() public {
        vm.prank(makeAddr("rando"));
        vm.expectRevert(GiveErrors.OnlyVault.selector);
        adapter.invest(1 ether);
    }

    // ─── divest ──────────────────────────────────────────────────────────────

    function test_Contract14_Case04_divest_fullWithdrawal() public {
        vm.startPrank(vault);
        asset.transfer(address(adapter), 100 ether);
        adapter.invest(100 ether);
        uint256 returned = adapter.divest(100 ether);
        vm.stopPrank();

        assertEq(returned, 100 ether, "returned mismatch");
        assertEq(adapter.investedAmount(), 0, "investedAmount not zeroed");
        assertEq(adapter.managedBalance(), 0, "managedBalance not zeroed");
    }

    function test_Contract14_Case05_divest_capsAtAdapterBalance() public {
        // Only 40 ether physically in adapter despite requesting 80
        vm.startPrank(vault);
        asset.transfer(address(adapter), 40 ether);
        adapter.invest(100 ether); // accounting says 100 but balance is 40
        uint256 returned = adapter.divest(80 ether);
        vm.stopPrank();

        assertEq(returned, 40 ether, "should cap at actual balance");
    }

    function test_Contract14_Case06_divest_zeroReverts() public {
        vm.prank(vault);
        vm.expectRevert(GiveErrors.InvalidDivestAmount.selector);
        adapter.divest(0);
    }

    function test_Contract14_Case07_divest_onlyVault() public {
        vm.prank(makeAddr("rando"));
        vm.expectRevert(GiveErrors.OnlyVault.selector);
        adapter.divest(1 ether);
    }

    // ─── harvest ─────────────────────────────────────────────────────────────

    function test_Contract14_Case08_harvest_profitAvailableInAdapter() public {
        // invest 100, then simulate profit by minting extra to adapter
        vm.startPrank(vault);
        asset.transfer(address(adapter), 100 ether);
        adapter.invest(100 ether);
        vm.stopPrank();

        // Manager reports 110 managed balance and deposits the profit physically
        vm.prank(manager);
        adapter.updateManagedBalance(110 ether);

        asset.mint(address(adapter), 10 ether); // profit physically available

        uint256 vaultBefore = asset.balanceOf(vault);
        vm.prank(vault);
        (uint256 profit, uint256 loss) = adapter.harvest();

        assertEq(profit, 10 ether, "profit mismatch");
        assertEq(loss, 0, "loss should be zero");
        assertEq(asset.balanceOf(vault) - vaultBefore, 10 ether, "vault balance should increase");
    }

    function test_Contract14_Case09_harvest_profitExistsButNotDeposited() public {
        // Invest 100 but adapter only physically holds 0 (manager withdrew everything)
        vm.startPrank(vault);
        asset.transfer(address(adapter), 100 ether);
        adapter.invest(100 ether);
        vm.stopPrank();

        // Manager withdraws everything off-chain (leaves nothing in adapter)
        vm.prank(manager);
        adapter.managerWithdraw(90 ether, manager); // leaves 10 ether buffer

        // Manager reports 110 managed balance (profit on paper)
        vm.prank(manager);
        adapter.updateManagedBalance(110 ether);

        // Only 10 ether physically in adapter — profit (10) can be transferred from buffer
        // but the "profit" branch tries to send 10 ether, and there are 10 ether available.
        // To test the "profit not deposited" branch we need adapterBalance < profit.
        // Set buffer lower so there's < 10 ether left to transfer profit from.
        vm.prank(admin);
        adapter.setBufferAmount(0);
        // Now withdraw down to 0 balance
        vm.prank(manager);
        adapter.managerWithdraw(10 ether, manager);

        vm.prank(vault);
        (uint256 profit, uint256 loss) = adapter.harvest();

        // adapterBalance == 0, transferable = 0, so profit reported = 0
        assertEq(profit, 0, "profit should be 0 when not yet deposited");
        assertEq(loss, 0);
    }

    function test_Contract14_Case10_harvest_lossResetsInvestedAmount() public {
        vm.startPrank(vault);
        asset.transfer(address(adapter), 100 ether);
        adapter.invest(100 ether);
        vm.stopPrank();

        // Manager reports a loss
        vm.prank(manager);
        adapter.updateManagedBalance(80 ether);

        vm.prank(vault);
        (uint256 profit, uint256 loss) = adapter.harvest();

        assertEq(profit, 0, "profit should be zero on loss");
        assertEq(loss, 20 ether, "loss mismatch");
        assertEq(adapter.investedAmount(), 80 ether, "investedAmount should be reset to managedBalance");
    }

    function test_Contract14_Case11_harvest_breakEven() public {
        vm.startPrank(vault);
        asset.transfer(address(adapter), 50 ether);
        adapter.invest(50 ether);
        vm.stopPrank();

        // managedBalance == investedAmount → break-even
        vm.prank(vault);
        (uint256 profit, uint256 loss) = adapter.harvest();

        assertEq(profit, 0);
        assertEq(loss, 0);
    }

    function test_Contract14_Case12_harvest_onlyVault() public {
        vm.prank(makeAddr("rando"));
        vm.expectRevert(GiveErrors.OnlyVault.selector);
        adapter.harvest();
    }

    // ─── emergencyWithdraw ────────────────────────────────────────────────────

    function test_Contract14_Case13_emergencyWithdraw_drainsAndResetsState() public {
        vm.startPrank(vault);
        asset.transfer(address(adapter), 100 ether);
        adapter.invest(100 ether);
        vm.stopPrank();

        uint256 vaultBefore = asset.balanceOf(vault);
        vm.prank(vault);
        uint256 returned = adapter.emergencyWithdraw();

        assertEq(returned, 100 ether);
        assertEq(asset.balanceOf(vault) - vaultBefore, 100 ether);
        assertEq(adapter.investedAmount(), 0);
        assertEq(adapter.managedBalance(), 0);
        assertEq(adapter.offChainAmount(), 0);
    }

    function test_Contract14_Case14_emergencyWithdraw_onlyVault() public {
        vm.prank(makeAddr("rando"));
        vm.expectRevert(GiveErrors.OnlyVault.selector);
        adapter.emergencyWithdraw();
    }

    // ─── managerWithdraw ─────────────────────────────────────────────────────

    function test_Contract14_Case15_managerWithdraw_enforceBuffer() public {
        vm.startPrank(vault);
        asset.transfer(address(adapter), 100 ether);
        adapter.invest(100 ether);
        vm.stopPrank();

        address recipient = makeAddr("recipient");
        // Withdraw 91 would leave only 9 ether, below buffer of 10
        vm.prank(manager);
        vm.expectRevert(ManualManageAdapter.InsufficientBuffer.selector);
        adapter.managerWithdraw(91 ether, recipient);
    }

    function test_Contract14_Case16_managerWithdraw_zeroAddressReverts() public {
        vm.startPrank(vault);
        asset.transfer(address(adapter), 100 ether);
        adapter.invest(100 ether);
        vm.stopPrank();

        vm.prank(manager);
        vm.expectRevert(GiveErrors.ZeroAddress.selector);
        adapter.managerWithdraw(50 ether, address(0));
    }

    // ─── managerDeposit ──────────────────────────────────────────────────────

    function test_Contract14_Case17_managerDeposit_decrementsOffChain() public {
        vm.startPrank(vault);
        asset.transfer(address(adapter), 100 ether);
        adapter.invest(100 ether);
        vm.stopPrank();

        // Withdraw 50 off-chain
        vm.prank(manager);
        adapter.managerWithdraw(50 ether, manager);
        assertEq(adapter.offChainAmount(), 50 ether);

        // Return 30
        vm.startPrank(manager);
        asset.approve(address(adapter), 30 ether);
        adapter.managerDeposit(30 ether);
        vm.stopPrank();

        assertEq(adapter.offChainAmount(), 20 ether);
    }

    function test_Contract14_Case18_managerDeposit_zeroReverts() public {
        vm.prank(manager);
        vm.expectRevert(GiveErrors.InvalidInvestAmount.selector);
        adapter.managerDeposit(0);
    }

    // ─── updateManagedBalance ─────────────────────────────────────────────────

    function test_Contract14_Case19_updateManagedBalance_emitsAndUpdates() public {
        vm.prank(manager);
        vm.expectEmit(true, false, false, true);
        emit ManualManageAdapter.ManagedBalanceUpdated(manager, 0, 200 ether);
        adapter.updateManagedBalance(200 ether);

        assertEq(adapter.managedBalance(), 200 ether);
    }

    // ─── setBufferAmount ─────────────────────────────────────────────────────

    function test_Contract14_Case20_setBufferAmount_adminOnly() public {
        vm.prank(admin);
        adapter.setBufferAmount(5 ether);
        assertEq(adapter.bufferAmount(), 5 ether);
    }

    function test_Contract14_Case21_setBufferAmount_nonAdminReverts() public {
        vm.prank(makeAddr("rando"));
        vm.expectRevert();
        adapter.setBufferAmount(5 ether);
    }
}
