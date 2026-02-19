// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {ForkBase} from "./ForkBase.t.sol";
import {ForkAddresses} from "./ForkAddresses.sol";
import {GiveVault4626} from "../../src/vault/GiveVault4626.sol";
import {AaveAdapter} from "../../src/adapters/AaveAdapter.sol";
import {IYieldAdapter} from "../../src/interfaces/IYieldAdapter.sol";

contract ForkMockACLForEth {
    function hasRole(bytes32, address) external pure returns (bool) {
        return false;
    }
}

/// @title DepositETHForkTest
/// @notice Covers ETH-native vault flows on Base fork:
///         depositETH -> wrap -> invest, withdrawETH -> divest -> unwrap,
///         and config/slippage reverts.
contract DepositETHForkTest is ForkBase {
    GiveVault4626 internal vault;
    AaveAdapter internal adapter;

    address internal admin;
    address internal receiver;

    uint256 internal constant DEPOSIT_AMOUNT = 1 ether;

    function setUp() public override {
        super.setUp();
        if (!_forkActive) return;

        admin = makeAddr("eth_vault_admin");
        receiver = makeAddr("eth_receiver");

        ForkMockACLForEth acl = new ForkMockACLForEth();

        vault = new GiveVault4626();
        vm.prank(admin);
        vault.initialize(
            ForkAddresses.WETH,
            "Give WETH Vault",
            "gWETH",
            admin,
            address(acl),
            address(vault)
        );

        adapter = new AaveAdapter(
            ForkAddresses.WETH,
            address(vault),
            ForkAddresses.AAVE_POOL,
            admin
        );

        vm.startPrank(admin);
        vault.setActiveAdapter(IYieldAdapter(address(adapter)));
        vault.setWrappedNative(ForkAddresses.WETH);
        vault.setCashBufferBps(0);
        vm.stopPrank();
    }

    function test_depositETH_wraps_and_invests_into_aave() public requiresFork {
        uint256 aTokenBefore = adapter.totalAssets();

        vm.deal(receiver, DEPOSIT_AMOUNT);
        vm.prank(receiver);
        uint256 shares = vault.depositETH{value: DEPOSIT_AMOUNT}(receiver, 0);

        assertGt(shares, 0, "no shares minted");
        assertEq(
            IERC20(ForkAddresses.WETH).balanceOf(address(vault)),
            0,
            "vault should not retain WETH with 0 cash buffer"
        );
        assertGt(adapter.totalAssets(), aTokenBefore, "adapter did not receive invested WETH");

        uint256 totalAssetsAfter = vault.totalAssets();
        assertApproxEqAbs(totalAssetsAfter, DEPOSIT_AMOUNT, 1, "vault totalAssets mismatch");
    }

    function test_withdrawETH_unwraps_and_returns_native() public requiresFork {
        vm.deal(receiver, DEPOSIT_AMOUNT);
        vm.prank(receiver);
        vault.depositETH{value: DEPOSIT_AMOUNT}(receiver, 0);

        uint256 nativeBefore = receiver.balance;
        vm.prank(receiver);
        uint256 burnedShares = vault.withdrawETH(0.9 ether, receiver, receiver, type(uint256).max);
        uint256 nativeAfter = receiver.balance;

        assertGt(burnedShares, 0, "no shares burned on withdrawETH");
        assertEq(nativeAfter - nativeBefore, 0.9 ether, "receiver did not get expected ETH amount");
    }

    function test_redeemETH_unwraps_and_returns_native() public requiresFork {
        vm.deal(receiver, DEPOSIT_AMOUNT);
        vm.prank(receiver);
        uint256 mintedShares = vault.depositETH{value: DEPOSIT_AMOUNT}(receiver, 0);

        uint256 sharesToRedeem = mintedShares / 2;
        uint256 minAssets = vault.previewRedeem(sharesToRedeem);
        uint256 nativeBefore = receiver.balance;

        vm.prank(receiver);
        uint256 assetsOut = vault.redeemETH(sharesToRedeem, receiver, receiver, minAssets);
        uint256 nativeAfter = receiver.balance;

        assertEq(assetsOut, minAssets, "redeemETH returned unexpected assets");
        assertEq(nativeAfter - nativeBefore, assetsOut, "receiver did not get redeemed ETH");
    }

    function test_depositETH_reverts_when_wrappedNative_not_set() public requiresFork {
        ForkMockACLForEth acl = new ForkMockACLForEth();
        GiveVault4626 freshVault = new GiveVault4626();

        vm.prank(admin);
        freshVault.initialize(
            ForkAddresses.WETH,
            "Give WETH Vault",
            "gWETH",
            admin,
            address(acl),
            address(freshVault)
        );

        vm.deal(receiver, DEPOSIT_AMOUNT);
        vm.prank(receiver);
        vm.expectRevert(GiveVault4626.InvalidConfiguration.selector);
        freshVault.depositETH{value: DEPOSIT_AMOUNT}(receiver, 0);
    }

    function test_depositETH_reverts_below_minShares() public requiresFork {
        vm.deal(receiver, DEPOSIT_AMOUNT);

        uint256 expectedShares = vault.previewDeposit(DEPOSIT_AMOUNT);

        vm.prank(receiver);
        vm.expectRevert(
            abi.encodeWithSelector(
                GiveVault4626.SlippageExceeded.selector,
                type(uint256).max,
                expectedShares
            )
        );
        vault.depositETH{value: DEPOSIT_AMOUNT}(receiver, type(uint256).max);
    }
}
