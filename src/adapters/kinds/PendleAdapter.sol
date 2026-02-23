// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import "pendle-core-v2-public/interfaces/IPActionSimple.sol";
import "pendle-core-v2-public/interfaces/IPActionSwapPTV3.sol";
import {
    TokenInput,
    TokenOutput,
    LimitOrderData,
    createTokenInputSimple,
    createTokenOutputSimple,
    createEmptyLimitOrderData
} from "pendle-core-v2-public/interfaces/IPAllActionTypeV3.sol";

import "../base/AdapterBase.sol";
import "../../utils/GiveErrors.sol";

/**
 * @title PendleAdapter
 * @author GIVE Labs
 * @notice Yield adapter that integrates fixed-maturity PT positions through Pendle Router V4
 * @dev Uses Pendle simple swap for tokenIn->PT (invest) and PT->tokenOut (divest/emergency).
 *
 *      TOKEN ROUTING — Pendle SY contracts restrict which tokens can be used as output on
 *      PT redemption. For yield-bearing markets (e.g. PT-yoUSD, PT-yoETH) the SY only
 *      accepts its own underlying asset (yoUSD, yoETH) as `tokenOut`, NOT the raw input
 *      asset (USDC, WETH). To support both classes of market with one adapter:
 *
 *        - `asset()` = the token donors deposit and receive back (e.g. USDC, WETH)
 *        - `tokenOut` = the token the Pendle SY will release on PT redemption
 *
 *      For standard markets (e.g. PT-aUSDC) tokenIn == tokenOut == USDC.
 *      For yield-bearing markets (e.g. PT-yoUSD) tokenIn == USDC but tokenOut == yoUSD.
 *
 *      When tokenOut != asset, the adapter holds the returned tokenOut temporarily.
 *      The vault is responsible for converting tokenOut -> asset if needed (e.g. via a
 *      separate swap or by accepting the yield-bearing token directly). In production
 *      deployments where asset == tokenOut this is a no-op identity transfer.
 *
 *      Principal is tracked in `deposits` for vault accounting compatibility.
 *      harvest() returns (0, 0) — PT yield is embedded in the PT price at maturity.
 */
contract PendleAdapter is AdapterBase {
    using SafeERC20 for IERC20;

    /// @notice Pendle Router V4 address (same on all chains via CREATE2)
    address public immutable router;

    /// @notice Pendle market address for this adapter
    address public immutable market;

    /// @notice Principal token received from Pendle on invest
    IERC20 public immutable ptToken;

    /// @notice Token the Pendle SY releases on PT redemption.
    ///         Equals asset() for standard markets; equals the SY underlying for
    ///         yield-bearing markets (e.g. yoUSD for PT-yoUSD, yoETH for PT-yoETH).
    ///         Must be in the SY's getTokensOut() list for the configured market.
    IERC20 public immutable tokenOut;

    /// @notice Tracked principal deposited by vault (denominated in asset units)
    uint256 public deposits;

    /**
     * @param adapterId   Unique identifier for this adapter instance
     * @param asset_      Token donors deposit (e.g. USDC, WETH)
     * @param vault_      Bound vault — only this address may call invest/divest/harvest
     * @param router_     Pendle Router V4 (0x888888888889758F76e7103c6CbF23ABbF58F946)
     * @param market_     Pendle market address
     * @param ptToken_    PT token address for this market
     * @param tokenOut_   Token the SY releases on redemption (use asset_ if market outputs asset
     *                    directly; use the SY underlying address for yield-bearing markets)
     */
    constructor(
        bytes32 adapterId,
        address asset_,
        address vault_,
        address router_,
        address market_,
        address ptToken_,
        address tokenOut_
    ) AdapterBase(adapterId, asset_, vault_) {
        if (router_ == address(0) || market_ == address(0) || ptToken_ == address(0) || tokenOut_ == address(0)) {
            revert GiveErrors.InvalidConfiguration();
        }

        router = router_;
        market = market_;
        ptToken = IERC20(ptToken_);
        tokenOut = IERC20(tokenOut_);
    }

    // ── IYieldAdapter ─────────────────────────────────────────────────────────

    /// @notice Returns tracked principal. PT positions have no streaming yield to report.
    function totalAssets() external view override returns (uint256) {
        return deposits;
    }

    /**
     * @notice Swap `assets` of the vault asset for PT via Pendle Router.
     * @dev The vault must transfer `assets` to this adapter before calling invest().
     *      Pendle Router pulls from adapter's allowance, not from vault directly.
     */
    function invest(uint256 assets) external override onlyVault {
        if (assets == 0) revert GiveErrors.InvalidInvestAmount();

        TokenInput memory input = createTokenInputSimple(address(asset()), assets);

        asset().forceApprove(router, 0);
        asset().forceApprove(router, assets);

        IPActionSimple(router).swapExactTokenForPtSimple(address(this), market, 0, input);

        deposits += assets;
        emit Invested(assets);
    }

    /**
     * @notice Redeem a proportional share of PT for tokenOut and transfer to vault.
     * @dev For standard markets (tokenOut == asset): vault receives asset directly.
     *      For yield-bearing markets (tokenOut != asset): vault receives tokenOut.
     *      The Pendle Router must be able to route PT -> tokenOut via the SY.
     */
    function divest(uint256 assets) external override onlyVault returns (uint256 returned) {
        if (assets == 0) revert GiveErrors.InvalidDivestAmount();

        uint256 ptBalance = ptToken.balanceOf(address(this));
        if (ptBalance == 0 || deposits == 0) {
            emit Divested(assets, 0);
            return 0;
        }

        uint256 ptToSell = assets >= deposits ? ptBalance : (ptBalance * assets) / deposits;
        if (ptToSell == 0) ptToSell = 1;

        TokenOutput memory output = createTokenOutputSimple(address(tokenOut), 0);
        LimitOrderData memory emptyLimit = createEmptyLimitOrderData();

        ptToken.forceApprove(router, 0);
        ptToken.forceApprove(router, ptToSell);

        (returned,,) = IPActionSwapPTV3(router).swapExactPtForToken(address(this), market, ptToSell, output, emptyLimit);

        if (returned > 0) {
            tokenOut.safeTransfer(vault(), returned);
        }

        uint256 principalReduced = ptToSell == ptBalance ? deposits : (deposits * ptToSell) / ptBalance;
        if (principalReduced == 0) principalReduced = 1;
        if (principalReduced > deposits) principalReduced = deposits;

        deposits -= principalReduced;

        emit Divested(assets, returned);
    }

    /// @notice PT adapters have no streaming yield. Harvest is a no-op.
    function harvest() external view override onlyVault returns (uint256, uint256) {
        return (0, 0);
    }

    /**
     * @notice Liquidate entire PT position and send proceeds to vault.
     * @dev On yield-bearing markets the vault receives tokenOut, not asset.
     *      Idle asset balance (if any) is also swept to vault.
     */
    function emergencyWithdraw() external override onlyVault returns (uint256 returned) {
        uint256 ptBalance = ptToken.balanceOf(address(this));
        if (ptBalance > 0) {
            TokenOutput memory output = createTokenOutputSimple(address(tokenOut), 0);
            LimitOrderData memory emptyLimit = createEmptyLimitOrderData();

            ptToken.forceApprove(router, 0);
            ptToken.forceApprove(router, ptBalance);

            (returned,,) =
                IPActionSwapPTV3(router).swapExactPtForToken(address(this), market, ptBalance, output, emptyLimit);

            if (returned > 0) {
                tokenOut.safeTransfer(vault(), returned);
            }
        }

        // Sweep any idle asset balance (covers partial invest or rounding dust)
        uint256 idleAsset = asset().balanceOf(address(this));
        if (idleAsset > 0) {
            asset().safeTransfer(vault(), idleAsset);
        }

        deposits = 0;
        emit EmergencyWithdraw(returned);
    }
}
