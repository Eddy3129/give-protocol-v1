// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import "../base/AdapterBase.sol";
import "../../utils/GiveErrors.sol";

/**
 * @title PTAdapter
 * @author GIVE Labs
 * @notice Yield adapter for Principal Token (PT) strategies with fixed maturity dates
 * @dev Models protocols with time-based fixed-maturity instruments (e.g., Pendle PT, Element PT).
 *      Tracks deposits and maturity series. No yield harvesting - profit realized at maturity.
 *
 *      Principal Token Model:
 *      - Series: Time-bound maturity window with start and end timestamps
 *      - deposits: Amount of principal locked in current series
 *      - No compounding or growth index - fixed principal until maturity
 *
 *      Use Cases:
 *      - Pendle Principal Tokens (PT)
 *      - Element Finance fixed-rate positions
 *      - Notional Finance fCash
 *      - Any fixed-maturity zero-coupon instrument
 *
 *      Lifecycle:
 *      1. Initialize with series (start, maturity)
 *      2. invest() locks principal for duration
 *      3. At maturity, divest() to redeem
 *      4. rollover() to new series if needed
 *
 *      Security Notes:
 *      - No yield harvesting (harvest returns 0,0)
 *      - Maturity enforcement must be handled by vault/strategy
 *      - Rollover can only be called by vault
 */
contract PTAdapter is AdapterBase {
    using SafeERC20 for IERC20;

    error InvalidSeriesWindow(uint64 start, uint64 maturity);
    error SeriesNotActive(uint64 start, uint64 maturity, uint64 currentTime);
    error SeriesAlreadyMatured(uint64 maturity, uint64 currentTime);
    error ActiveSeriesHasDeposits(uint256 deposits);
    error InsufficientAdapterBalance(uint256 required, uint256 available);

    event SeriesConfigured(uint64 indexed start, uint64 indexed maturity);
    event SeriesRollover(uint64 indexed oldStart, uint64 indexed oldMaturity, uint64 indexed newStart, uint64 newMaturity);

    // ============================================
    // STRUCTS
    // ============================================

    /**
     * @notice Represents a fixed-maturity series
     * @param start Timestamp when series becomes active
     * @param maturity Timestamp when principal can be redeemed
     */
    struct Series {
        uint64 start;
        uint64 maturity;
    }

    // ============================================
    // STATE VARIABLES
    // ============================================

    /// @notice Current active series with start and maturity dates
    Series public currentSeries;

    /// @notice Total deposits locked in current series
    uint256 public deposits;

    // ============================================
    // CONSTRUCTOR
    // ============================================

    /**
     * @notice Initializes the PT adapter with an initial series
     * @param adapterId Unique identifier for this adapter
     * @param asset Underlying asset address
     * @param vault Vault address authorized to use this adapter
     * @param start Series start timestamp
     * @param maturity Series maturity timestamp
     */
    constructor(bytes32 adapterId, address asset, address vault, uint64 start, uint64 maturity)
        AdapterBase(adapterId, asset, vault)
    {
        _validateSeriesWindow(start, maturity);
        currentSeries = Series(start, maturity);
        emit SeriesConfigured(start, maturity);
    }

    // ============================================
    // IYIELDADAPTER IMPLEMENTATION
    // ============================================

    /**
     * @notice Returns total assets under management (fixed deposits)
     * @dev For PTs, total assets equals deposits (no appreciation until maturity)
     * @return Total deposits in current series
     */
    function totalAssets() external view override returns (uint256) {
        return deposits;
    }

    /**
     * @notice Invests assets into the current PT series
     * @dev Records deposit for current maturity window.
     *      In production, vault would mint/purchase PT tokens.
     * @param assets Amount of assets to invest
     */
    function invest(uint256 assets) external override onlyVault {
        if (assets == 0) revert GiveErrors.InvalidInvestAmount();

        Series memory series = currentSeries;
        uint64 currentTime = uint64(block.timestamp);
        if (currentTime < series.start || currentTime >= series.maturity) {
            revert SeriesNotActive(series.start, series.maturity, currentTime);
        }

        uint256 adapterBalance = asset().balanceOf(address(this));
        if (adapterBalance < deposits + assets) {
            revert InsufficientAdapterBalance(deposits + assets, adapterBalance);
        }

        deposits += assets;
        emit Invested(assets);
    }

    /**
     * @notice Divests assets from the PT series
     * @dev Withdraws principal (typically at or after maturity).
     *      Caps withdrawal at available deposits. Transfers assets back to vault.
     * @param assets Amount of assets to divest
     * @return returned Actual amount of assets returned to vault
     */
    function divest(uint256 assets) external override onlyVault returns (uint256 returned) {
        if (assets == 0) revert GiveErrors.InvalidDivestAmount();

        uint256 requested = assets;

        // Cap at available deposits
        if (assets > deposits) assets = deposits;

        deposits -= assets;
        returned = assets;

        asset().safeTransfer(vault(), assets);
        emit Divested(requested, returned);
    }

    /**
     * @notice Harvest function (no-op for PT adapters)
     * @dev Principal Tokens don't harvest yield incrementally.
     *      Yield is realized at maturity via redemption, not harvesting.
     * @return profit Always 0 (no incremental yield)
     * @return loss Always 0 (no loss tracking)
     */
    function harvest() external view override onlyVault returns (uint256, uint256) {
        return (0, 0);
    }

    /**
     * @notice Emergency withdrawal of all deposits
     * @dev Returns all locked principal to vault, resets deposit counter.
     *      Does NOT transfer assets (assumes vault handles emergency separately).
     * @return returned Total deposits in current series
     */
    function emergencyWithdraw() external override onlyVault returns (uint256 returned) {
        returned = asset().balanceOf(address(this));

        if (returned > 0) {
            asset().safeTransfer(vault(), returned);
        }

        deposits = 0;
        emit EmergencyWithdraw(returned);
    }

    // ============================================
    // SERIES MANAGEMENT
    // ============================================

    /**
     * @notice Rolls over to a new PT series
     * @dev Only callable by vault. Used when current series matures and new one begins.
     *      Typically called after divesting from old series.
     * @param newStart New series start timestamp
     * @param newMaturity New series maturity timestamp
     */
    function rollover(uint64 newStart, uint64 newMaturity) external onlyVault {
        _validateSeriesWindow(newStart, newMaturity);

        Series memory series = currentSeries;
        uint64 currentTime = uint64(block.timestamp);
        if (deposits > 0 && currentTime < series.maturity) {
            revert ActiveSeriesHasDeposits(deposits);
        }
        if (deposits > 0 && currentTime >= series.maturity) {
            revert SeriesAlreadyMatured(series.maturity, currentTime);
        }

        currentSeries = Series(newStart, newMaturity);
        emit SeriesRollover(series.start, series.maturity, newStart, newMaturity);
    }

    function _validateSeriesWindow(uint64 start, uint64 maturity) private pure {
        if (start == 0 || maturity <= start) {
            revert InvalidSeriesWindow(start, maturity);
        }
    }
}
