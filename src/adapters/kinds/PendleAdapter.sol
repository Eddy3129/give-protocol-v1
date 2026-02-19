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
 * @notice Yield adapter that integrates fixed-maturity PT positions through Pendle Router V4 interfaces
 * @dev Uses Pendle simple swap for token->PT and PT->token swap for exits.
 *      Principal is tracked in `deposits` for vault accounting compatibility.
 */
contract PendleAdapter is AdapterBase {
    using SafeERC20 for IERC20;

    /// @notice Pendle Router address used for swaps
    address public immutable router;

    /// @notice Pendle market used by this adapter
    address public immutable market;

    /// @notice Principal token for the configured Pendle market
    IERC20 public immutable ptToken;

    /// @notice Tracked principal deposited by vault
    uint256 public deposits;

    constructor(bytes32 adapterId, address asset, address vault, address router_, address market_, address ptToken_)
        AdapterBase(adapterId, asset, vault)
    {
        if (router_ == address(0) || market_ == address(0) || ptToken_ == address(0)) {
            revert GiveErrors.InvalidConfiguration();
        }

        router = router_;
        market = market_;
        ptToken = IERC20(ptToken_);
    }

    function totalAssets() external view override returns (uint256) {
        return deposits;
    }

    function invest(uint256 assets) external override onlyVault {
        if (assets == 0) revert GiveErrors.InvalidInvestAmount();

        TokenInput memory input = createTokenInputSimple(address(asset()), assets);

        asset().forceApprove(router, 0);
        asset().forceApprove(router, assets);

        IPActionSimple(router).swapExactTokenForPtSimple(address(this), market, 0, input);

        deposits += assets;
        emit Invested(assets);
    }

    function divest(uint256 assets) external override onlyVault returns (uint256 returned) {
        if (assets == 0) revert GiveErrors.InvalidDivestAmount();

        uint256 ptBalance = ptToken.balanceOf(address(this));
        if (ptBalance == 0 || deposits == 0) {
            emit Divested(assets, 0);
            return 0;
        }

        uint256 ptToSell = assets >= deposits ? ptBalance : (ptBalance * assets) / deposits;
        if (ptToSell == 0) ptToSell = 1;

        TokenOutput memory output = createTokenOutputSimple(address(asset()), 0);
        LimitOrderData memory emptyLimit = createEmptyLimitOrderData();

        ptToken.forceApprove(router, 0);
        ptToken.forceApprove(router, ptToSell);

        (returned,,) = IPActionSwapPTV3(router).swapExactPtForToken(address(this), market, ptToSell, output, emptyLimit);

        if (returned > 0) {
            asset().safeTransfer(vault(), returned);
        }

        uint256 principalReduced = ptToSell == ptBalance ? deposits : (deposits * ptToSell) / ptBalance;
        if (principalReduced == 0) principalReduced = 1;
        if (principalReduced > deposits) principalReduced = deposits;

        deposits -= principalReduced;

        emit Divested(assets, returned);
    }

    function harvest() external view override onlyVault returns (uint256, uint256) {
        return (0, 0);
    }

    function emergencyWithdraw() external override onlyVault returns (uint256 returned) {
        uint256 ptBalance = ptToken.balanceOf(address(this));
        if (ptBalance > 0) {
            TokenOutput memory output = createTokenOutputSimple(address(asset()), 0);
            LimitOrderData memory emptyLimit = createEmptyLimitOrderData();

            ptToken.forceApprove(router, 0);
            ptToken.forceApprove(router, ptBalance);

            (returned,,) =
                IPActionSwapPTV3(router).swapExactPtForToken(address(this), market, ptBalance, output, emptyLimit);
        }

        uint256 idleBalance = asset().balanceOf(address(this));
        if (idleBalance > 0) {
            asset().safeTransfer(vault(), idleBalance);
            returned = idleBalance;
        }

        deposits = 0;
        emit EmergencyWithdraw(returned);
    }
}
