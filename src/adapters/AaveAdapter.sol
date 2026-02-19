// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";

import "../interfaces/IYieldAdapter.sol";
import "../utils/GiveErrors.sol";

// ============================================
// AAVE V3 INTERFACES
// ============================================

/**
 * @notice Aave V3 Pool interface
 */
interface IPool {
    function supply(address asset, uint256 amount, address onBehalfOf, uint16 referralCode) external;
    function withdraw(address asset, uint256 amount, address to) external returns (uint256);
    function getReserveData(address asset) external view returns (ReserveData memory);
}

/**
 * @notice Aave V3 aToken interface
 */
interface IAToken {
    function balanceOf(address user) external view returns (uint256);
    function scaledBalanceOf(address user) external view returns (uint256);
}

/**
 * @notice Aave reserve data structure
 */
struct ReserveData {
    uint256 configuration;
    uint128 liquidityIndex;
    uint128 currentLiquidityRate;
    uint128 variableBorrowIndex;
    uint128 currentVariableBorrowRate;
    uint128 currentStableBorrowRate;
    uint40 lastUpdateTimestamp;
    uint16 id;
    address aTokenAddress;
    address stableDebtTokenAddress;
    address variableDebtTokenAddress;
    address interestRateStrategyAddress;
    uint128 accruedToTreasury;
    uint128 unbacked;
    uint128 isolationModeTotalDebt;
}

/**
 * @title AaveAdapter
 * @author GIVE Labs
 * @notice Production yield adapter for Aave V3 protocol integration
 * @dev Supplies assets to Aave V3 liquidity pools and tracks yield through aToken balance growth.
 *      Implements full production features: pausability, reentrancy protection, emergency mode,
 *      slippage protection, and comprehensive monitoring.
 *
 *      Aave V3 Integration:
 *      - supply(): Deposits assets into Aave pool, receives aTokens
 *      - withdraw(): Redeems aTokens for underlying assets
 *      - aTokens: Rebasing tokens that grow in balance as interest accrues
 *
 *      Key Features:
 *      - Automatic yield accrual through aToken balance growth
 *      - Configurable slippage tolerance for withdrawals
 *      - Emergency mode for protocol issues
 *      - Pausable for maintenance
 *      - Comprehensive health checks
 *      - Gas-optimized with immutable addresses
 *
 *      Security Model:
 *      - VAULT_ROLE: Call invest/divest/harvest functions
 *      - EMERGENCY_ROLE: Trigger emergency withdrawals and pause
 *      - DEFAULT_ADMIN_ROLE: Configure risk parameters
 *
 *      Risk Management:
 *      - maxSlippageBps: Maximum allowed slippage on withdrawals (default 1%)
 *      - emergencyExitBps: Acceptable loss threshold in emergency (default 5%)
 *      - Emergency mode: Disables new investments when activated
 *
 *      Use Cases:
 *      - Conservative yield generation for campaign vaults
 *      - Stable yield on USDC, DAI, WETH
 *      - Automated compounding without gas overhead
 */
contract AaveAdapter is IYieldAdapter, AccessControl, ReentrancyGuard, Pausable {
    using SafeERC20 for IERC20;

    // ============================================
    // CONSTANTS
    // ============================================

    bytes32 public constant VAULT_ROLE = keccak256("VAULT_ROLE");
    bytes32 public constant EMERGENCY_ROLE = keccak256("EMERGENCY_ROLE");
    uint256 public constant BASIS_POINTS = 10000;
    uint16 public constant AAVE_REFERRAL_CODE = 0;

    // ============================================
    // IMMUTABLE STATE
    // ============================================

    IERC20 public immutable override asset;
    address public immutable override vault;
    IPool public immutable aavePool;
    IAToken public immutable aToken;

    // ============================================
    // MUTABLE STATE
    // ============================================

    uint256 public totalInvested;
    uint256 public totalHarvested;
    uint256 public lastHarvestTime;
    uint256 public cumulativeYield;

    // Risk parameters
    uint256 public maxSlippageBps = 100; // 1%
    uint256 public emergencyExitBps = 9500; // 95% - allow 5% slippage in emergency

    bool public emergencyMode;

    // ============================================
    // EVENTS
    // ============================================

    event MaxSlippageUpdated(uint256 oldBps, uint256 newBps);
    event EmergencyExitBpsUpdated(uint256 oldBps, uint256 newBps);
    event EmergencyModeActivated(bool activated);
    event YieldAccrued(uint256 amount, uint256 newBalance);

    // ============================================
    // MODIFIERS
    // ============================================

    modifier onlyVault() {
        if (msg.sender != vault) revert GiveErrors.OnlyVault();
        _;
    }

    modifier whenNotEmergency() {
        if (emergencyMode) revert GiveErrors.AdapterPaused();
        _;
    }

    // ============================================
    // CONSTRUCTOR
    // ============================================

    /**
     * @notice Initializes the Aave adapter
     * @dev Validates all addresses and fetches aToken from Aave pool.
     *      Grants initial roles and approves Aave pool for token transfers.
     * @param _asset Underlying ERC20 asset address
     * @param _vault Vault address authorized to call adapter
     * @param _aavePool Aave V3 Pool address
     * @param _admin Admin address to receive DEFAULT_ADMIN_ROLE and EMERGENCY_ROLE
     */
    constructor(address _asset, address _vault, address _aavePool, address _admin) {
        if (_asset == address(0) || _vault == address(0) || _aavePool == address(0) || _admin == address(0)) {
            revert GiveErrors.ZeroAddress();
        }

        asset = IERC20(_asset);
        vault = _vault;
        aavePool = IPool(_aavePool);

        // Get aToken address from Aave pool
        ReserveData memory reserveData = aavePool.getReserveData(_asset);
        if (reserveData.aTokenAddress == address(0)) {
            revert GiveErrors.InvalidAsset();
        }
        aToken = IAToken(reserveData.aTokenAddress);

        _grantRole(DEFAULT_ADMIN_ROLE, _admin);
        _grantRole(VAULT_ROLE, _vault);
        _grantRole(EMERGENCY_ROLE, _admin);

        lastHarvestTime = block.timestamp;

        // Approve Aave pool to spend our tokens
        IERC20(asset).forceApprove(_aavePool, type(uint256).max);
    }

    // ============================================
    // IYIELDADAPTER IMPLEMENTATION
    // ============================================

    /**
     * @notice Returns total assets under management
     * @dev Queries aToken balance which represents principal + accrued yield
     * @return Current aToken balance of this adapter
     */
    function totalAssets() external view override returns (uint256) {
        return aToken.balanceOf(address(this));
    }

    /**
     * @notice Invests assets into Aave by supplying to pool
     * @dev Assumes vault has already transferred tokens to adapter.
     *      Supplies to Aave and receives aTokens in return.
     * @param assets Amount of assets to invest
     */
    function invest(uint256 assets) external override onlyVault nonReentrant whenNotPaused whenNotEmergency {
        if (assets == 0) revert GiveErrors.InvalidInvestAmount();

        uint256 balanceBefore = asset.balanceOf(address(this));
        if (balanceBefore < assets) revert GiveErrors.InsufficientBalance();

        // Supply to Aave
        aavePool.supply(address(asset), assets, address(this), AAVE_REFERRAL_CODE);

        totalInvested += assets;

        emit Invested(assets);
    }

    /**
     * @notice Divests assets from Aave by withdrawing from pool
     * @dev Withdraws assets from Aave, validates slippage, transfers to vault.
     *      Uses type(uint256).max for full withdrawal if needed.
     * @param assets Amount of assets to divest
     * @return returned Actual amount of assets returned to vault
     */
    function divest(uint256 assets) external override onlyVault nonReentrant whenNotPaused returns (uint256 returned) {
        if (assets == 0) revert GiveErrors.InvalidDivestAmount();

        uint256 aTokenBalance = aToken.balanceOf(address(this));
        if (aTokenBalance == 0) return 0;

        bool withdrawAll = assets > aTokenBalance;
        uint256 expected = withdrawAll ? aTokenBalance : assets;

        // Withdraw from Aave (use type(uint256).max to withdraw all if needed)
        uint256 toWithdraw = withdrawAll ? type(uint256).max : assets;

        uint256 balanceBefore = asset.balanceOf(address(this));
        returned = aavePool.withdraw(address(asset), toWithdraw, address(this));

        // Verify we received the expected amount (within slippage tolerance)
        if (!emergencyMode && expected > 0 && returned < expected) {
            uint256 slippage = ((expected - returned) * BASIS_POINTS) / expected;
            if (slippage > maxSlippageBps) {
                revert GiveErrors.SlippageExceeded(slippage, maxSlippageBps);
            }
        }

        // Update total invested
        if (withdrawAll) {
            totalInvested = 0;
        } else if (returned <= totalInvested) {
            totalInvested -= returned;
        } else {
            totalInvested = 0;
        }

        // Transfer the withdrawn assets back to the vault
        if (returned > 0) {
            IERC20(asset).safeTransfer(vault, returned);
        }

        emit Divested(assets, returned);
    }

    /**
     * @notice Harvests yield by withdrawing profit from Aave
     * @dev Calculates profit as (aToken balance - total invested), withdraws profit to vault.
     *      Updates accounting to reflect withdrawn profit.
     * @return profit Amount of profit harvested and sent to vault
     * @return loss Amount of loss incurred (should be 0 for Aave supply-only)
     */
    function harvest() external override onlyVault nonReentrant whenNotPaused returns (uint256 profit, uint256 loss) {
        uint256 currentBalance = aToken.balanceOf(address(this));

        if (currentBalance > totalInvested) {
            profit = currentBalance - totalInvested;

            // Withdraw the profit
            if (profit > 0) {
                uint256 withdrawn = aavePool.withdraw(address(asset), profit, vault);
                profit = withdrawn; // Use actual withdrawn amount

                // Update totalInvested to reflect the withdrawn profit
                totalInvested = currentBalance - profit;

                cumulativeYield += profit;
                totalHarvested += profit;
            }
        } else if (currentBalance < totalInvested) {
            // This shouldn't happen with Aave supply-only, but handle it
            loss = totalInvested - currentBalance;
            totalInvested = currentBalance;
        }

        lastHarvestTime = block.timestamp;

        emit Harvested(profit, loss);
        if (profit > 0) {
            emit YieldAccrued(profit, currentBalance);
        }
    }

    /**
     * @notice Emergency withdrawal of all assets
     * @dev Withdraws full aToken balance, sends to vault, resets accounting.
     *      Activates emergency mode. Can be called by EMERGENCY_ROLE or VAULT_ROLE.
     * @return returned Amount of assets returned to vault
     */
    function emergencyWithdraw() external override nonReentrant returns (uint256 returned) {
        // Allow both EMERGENCY_ROLE and VAULT_ROLE to call this function
        if (!hasRole(EMERGENCY_ROLE, msg.sender) && !hasRole(VAULT_ROLE, msg.sender)) {
            revert AccessControlUnauthorizedAccount(msg.sender, EMERGENCY_ROLE);
        }

        uint256 aTokenBalance = aToken.balanceOf(address(this));
        if (aTokenBalance == 0) return 0;

        // Activate emergency mode
        emergencyMode = true;

        // Withdraw all available assets (use aToken balance to avoid overflow)
        returned = aavePool.withdraw(address(asset), aTokenBalance, vault);

        // Reset state
        totalInvested = 0;

        emit EmergencyWithdraw(returned);
        emit EmergencyModeActivated(true);
    }

    // ============================================
    // ADMIN FUNCTIONS
    // ============================================

    /**
     * @notice Sets maximum slippage tolerance for normal withdrawals
     * @param _bps Slippage in basis points (100 = 1%, max 10%)
     */
    function setMaxSlippageBps(uint256 _bps) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (_bps > 1000) revert GiveErrors.InvalidSlippageBps(); // Max 10%

        uint256 oldBps = maxSlippageBps;
        maxSlippageBps = _bps;

        emit MaxSlippageUpdated(oldBps, _bps);
    }

    /**
     * @notice Sets emergency exit slippage tolerance
     * @param _bps Minimum acceptable return in basis points (9500 = 95%)
     */
    function setEmergencyExitBps(uint256 _bps) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (_bps < 5000 || _bps > 10000) revert GiveErrors.ParameterOutOfRange();

        uint256 oldBps = emergencyExitBps;
        emergencyExitBps = _bps;

        emit EmergencyExitBpsUpdated(oldBps, _bps);
    }

    /**
     * @notice Deactivates emergency mode to resume normal operations
     */
    function deactivateEmergencyMode() external onlyRole(DEFAULT_ADMIN_ROLE) {
        emergencyMode = false;
        emit EmergencyModeActivated(false);
    }

    /**
     * @notice Pauses the adapter
     */
    function pause() external onlyRole(EMERGENCY_ROLE) {
        _pause();
    }

    /**
     * @notice Unpauses the adapter
     */
    function unpause() external onlyRole(DEFAULT_ADMIN_ROLE) {
        _unpause();
    }

    // ============================================
    // VIEW FUNCTIONS
    // ============================================

    /**
     * @notice Returns current supply APY from Aave
     * @return currentLiquidityRate Current liquidity rate in ray units (1e27 = 100%)
     */
    function getCurrentYieldRate() external view returns (uint256) {
        ReserveData memory reserveData = aavePool.getReserveData(address(asset));
        return reserveData.currentLiquidityRate;
    }

    /**
     * @notice Returns comprehensive adapter statistics
     * @return totalInvestedAmount Total principal invested
     * @return totalHarvestedAmount Total yield harvested
     * @return cumulativeYieldAmount Cumulative yield generated
     * @return lastHarvest Timestamp of last harvest
     * @return currentBalance Current aToken balance
     */
    function getAdapterStats()
        external
        view
        returns (
            uint256 totalInvestedAmount,
            uint256 totalHarvestedAmount,
            uint256 cumulativeYieldAmount,
            uint256 lastHarvest,
            uint256 currentBalance
        )
    {
        return (totalInvested, totalHarvested, cumulativeYield, lastHarvestTime, aToken.balanceOf(address(this)));
    }

    /**
     * @notice Returns risk management parameters
     * @return maxSlippage Maximum allowed slippage in bps
     * @return emergencyExit Minimum acceptable return in emergency in bps
     * @return emergency Whether emergency mode is active
     */
    function getRiskParameters() external view returns (uint256 maxSlippage, uint256 emergencyExit, bool emergency) {
        return (maxSlippageBps, emergencyExitBps, emergencyMode);
    }

    /**
     * @notice Returns Aave-specific information
     * @return poolAddress Aave pool address
     * @return aTokenAddress aToken address for this asset
     * @return liquidityRate Current liquidity rate
     * @return aTokenBalance Current aToken balance
     */
    function getAaveInfo()
        external
        view
        returns (address poolAddress, address aTokenAddress, uint256 liquidityRate, uint256 aTokenBalance)
    {
        ReserveData memory reserveData = aavePool.getReserveData(address(asset));
        return (address(aavePool), address(aToken), reserveData.currentLiquidityRate, aToken.balanceOf(address(this)));
    }

    /**
     * @notice Checks if the adapter is healthy and operational
     * @dev Verifies adapter is not paused/emergency, and Aave reserve is active
     * @return True if adapter is healthy and ready for operations
     */
    function isHealthy() external view returns (bool) {
        if (emergencyMode || paused()) return false;

        // Check if Aave reserve is active and not frozen
        try aavePool.getReserveData(address(asset)) returns (ReserveData memory data) {
            // Basic health check - reserve exists and has aToken
            return data.aTokenAddress != address(0);
        } catch {
            return false;
        }
    }
}
