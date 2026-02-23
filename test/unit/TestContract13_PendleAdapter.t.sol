// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {
    TokenInput,
    TokenOutput,
    LimitOrderData,
    createEmptyLimitOrderData
} from "pendle-core-v2-public/interfaces/IPAllActionTypeV3.sol";

import {PendleAdapter} from "../../src/adapters/kinds/PendleAdapter.sol";
import {GiveErrors} from "../../src/utils/GiveErrors.sol";
import {MockERC20} from "../../src/mocks/MockERC20.sol";

contract MockPendleRouter {
    using SafeERC20 for IERC20;

    MockERC20 public immutable assetToken;
    MockERC20 public immutable ptToken;
    address public immutable market;

    constructor(address asset_, address pt_, address market_) {
        assetToken = MockERC20(asset_);
        ptToken = MockERC20(pt_);
        market = market_;
    }

    function swapExactTokenForPtSimple(address receiver, address market_, uint256 minPtOut, TokenInput calldata input)
        external
        returns (uint256 netPtOut, uint256 netSyFee, uint256 netSyInterm)
    {
        require(market_ == market, "invalid market");

        IERC20(input.tokenIn).safeTransferFrom(msg.sender, address(this), input.netTokenIn);

        netPtOut = input.netTokenIn;
        require(netPtOut >= minPtOut, "insufficient pt out");

        ptToken.mint(receiver, netPtOut);

        netSyFee = 0;
        netSyInterm = input.netTokenIn;
    }

    function swapExactPtForToken(
        address receiver,
        address market_,
        uint256 exactPtIn,
        TokenOutput calldata output,
        LimitOrderData calldata
    ) external returns (uint256 netTokenOut, uint256 netSyFee, uint256 netSyInterm) {
        require(market_ == market, "invalid market");
        require(output.tokenOut == address(assetToken), "invalid token out");

        IERC20(address(ptToken)).safeTransferFrom(msg.sender, address(this), exactPtIn);

        netTokenOut = exactPtIn;
        assetToken.mint(receiver, netTokenOut);

        netSyFee = 0;
        netSyInterm = netTokenOut;
    }
}

contract TestContract13_PendleAdapter is Test {
    MockERC20 public asset;
    MockERC20 public pt;
    MockPendleRouter public router;
    PendleAdapter public adapter;

    address public vault;
    address public market;

    bytes32 public constant ADAPTER_ID = keccak256("PENDLE_ADAPTER");

    function setUp() public {
        asset = new MockERC20("USD Coin", "USDC", 6);
        pt = new MockERC20("Pendle PT", "PT", 18);

        vault = makeAddr("vault");
        market = makeAddr("pendleMarket");

        router = new MockPendleRouter(address(asset), address(pt), market);
        adapter =
            new PendleAdapter(ADAPTER_ID, address(asset), vault, address(router), market, address(pt), address(asset));

        asset.mint(vault, 1_000_000e6);
    }

    function test_Contract13_Case01_investBuysPtAndTracksPrincipal() public {
        vm.startPrank(vault);
        asset.transfer(address(adapter), 100_000e6);
        adapter.invest(100_000e6);
        vm.stopPrank();

        assertEq(adapter.deposits(), 100_000e6);
        assertEq(pt.balanceOf(address(adapter)), 100_000e6);
    }

    function test_Contract13_Case02_divestSellsProportionalPt() public {
        vm.startPrank(vault);
        asset.transfer(address(adapter), 100_000e6);
        adapter.invest(100_000e6);

        uint256 vaultBefore = asset.balanceOf(vault);
        uint256 returned = adapter.divest(40_000e6);
        vm.stopPrank();

        assertEq(returned, 40_000e6);
        assertEq(asset.balanceOf(vault), vaultBefore + 40_000e6);
        assertEq(adapter.deposits(), 60_000e6);
        assertEq(pt.balanceOf(address(adapter)), 60_000e6);
    }

    function test_Contract13_Case03_emergencyWithdrawExitsAll() public {
        vm.startPrank(vault);
        asset.transfer(address(adapter), 75_000e6);
        adapter.invest(75_000e6);

        uint256 vaultBefore = asset.balanceOf(vault);
        uint256 returned = adapter.emergencyWithdraw();
        vm.stopPrank();

        assertEq(returned, 75_000e6);
        assertEq(asset.balanceOf(vault), vaultBefore + 75_000e6);
        assertEq(adapter.deposits(), 0);
        assertEq(pt.balanceOf(address(adapter)), 0);
    }

    function test_Contract13_Case04_onlyVaultCanCallStateChangingFns() public {
        vm.expectRevert(abi.encodeWithSelector(GiveErrors.OnlyVault.selector));
        adapter.invest(1);

        vm.expectRevert(abi.encodeWithSelector(GiveErrors.OnlyVault.selector));
        adapter.divest(1);

        vm.expectRevert(abi.encodeWithSelector(GiveErrors.OnlyVault.selector));
        adapter.emergencyWithdraw();
    }

    function test_Contract13_Case05_invalidConfigReverts() public {
        vm.expectRevert(abi.encodeWithSelector(GiveErrors.InvalidConfiguration.selector));
        new PendleAdapter(ADAPTER_ID, address(asset), vault, address(0), market, address(pt), address(asset));

        vm.expectRevert(abi.encodeWithSelector(GiveErrors.InvalidConfiguration.selector));
        new PendleAdapter(ADAPTER_ID, address(asset), vault, address(router), address(0), address(pt), address(asset));

        vm.expectRevert(abi.encodeWithSelector(GiveErrors.InvalidConfiguration.selector));
        new PendleAdapter(ADAPTER_ID, address(asset), vault, address(router), market, address(0), address(asset));

        vm.expectRevert(abi.encodeWithSelector(GiveErrors.InvalidConfiguration.selector));
        new PendleAdapter(ADAPTER_ID, address(asset), vault, address(router), market, address(pt), address(0));
    }

    function test_Contract13_Case06_divestWithoutPositionReturnsZero() public {
        vm.prank(vault);
        uint256 returned = adapter.divest(1_000e6);

        assertEq(returned, 0);
        assertEq(adapter.deposits(), 0);
        assertEq(pt.balanceOf(address(adapter)), 0);
    }

    function test_Contract13_Case07_harvestIsNoop() public {
        vm.prank(vault);
        (uint256 profit, uint256 loss) = adapter.harvest();

        assertEq(profit, 0);
        assertEq(loss, 0);
    }

    function test_Contract13_Case08_divestZeroReverts() public {
        vm.prank(vault);
        vm.expectRevert(abi.encodeWithSelector(GiveErrors.InvalidDivestAmount.selector));
        adapter.divest(0);
    }

    function test_Contract13_Case09_investZeroReverts() public {
        vm.prank(vault);
        vm.expectRevert(abi.encodeWithSelector(GiveErrors.InvalidInvestAmount.selector));
        adapter.invest(0);
    }
}
