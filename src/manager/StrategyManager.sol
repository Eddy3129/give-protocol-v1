// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "../vault/GiveVault4626.sol";
import "../interfaces/IYieldAdapter.sol";
import "../registry/StrategyRegistry.sol";
import "../registry/CampaignRegistry.sol";
import "../types/GiveTypes.sol";
import "../utils/GiveErrors.sol";
import "../utils/ACLShim.sol";
import "../storage/StorageLib.sol";

/**
 * @title StrategyManager
 * @author GIVE Labs
 * @notice Manages strategy configuration and adapter parameters for GiveVault4626
 * @dev Provides centralized configuration surface for vault yield operations.
 *
 *      Key Responsibilities:
 *      - Approve and activate yield adapters for vaults
 *      - Configure vault operational parameters
 *      - Manage rebalancing between adapters
 *      - Handle emergency situations
 *      - Validate adapter-campaign compatibility
 *
 *      Architecture:
 *      - Extends ACLShim for role-based access control
 *      - ReentrancyGuard and Pausable inherited but not actively used
 *      - Emergency controls via explicit investPaused flag on vault
 *      - Immutable vault binding for gas efficiency
 *
 *      Adapter Management:
 *      - Maximum 10 approved adapters per manager
 *      - Adapters must match campaign strategy requirements
 *      - Active adapter can be changed for rebalancing
 *      - Approval changes trigger list maintenance
 *
 *      Rebalancing:
 *      - Manual rebalancing via rebalance()
 *      - Best-effort automatic rebalancing via checkAndRebalance() (opt-in, simple heuristic)
 *      - Configurable interval (1 hour - 30 days)
 *      - Adapter selection based on highest totalAssets() heuristic
 *      - Disabled during emergency mode
 *
 *      Emergency Controls:
 *      - Emergency mode activation/deactivation
 *      - Emergency withdrawal from adapter
 *      - Pause invest/harvest operations
 *      - Configurable loss threshold (max 50%)
 *
 *      Security Model:
 *      - STRATEGY_MANAGER_ROLE: Configuration management
 *      - EMERGENCY_ROLE: Emergency operations
 *      - DEFAULT_ADMIN_ROLE: Emergency mode deactivation
 *      - Campaign-adapter validation enforced
 *
 *      Use Cases:
 *      - Configure vault parameters → updateVaultParameters()
 *      - Switch yield strategy → setActiveAdapter()
 *      - Optimize yield → rebalance()
 *      - Handle emergencies → activateEmergencyMode() + emergencyWithdraw()
 */
contract StrategyManager is ACLShim, ReentrancyGuard, Pausable {
    // ============================================
    // ROLES
    // ============================================

    /// @notice Role required for strategy management operations
    bytes32 public constant STRATEGY_MANAGER_ROLE = keccak256("STRATEGY_MANAGER_ROLE");

    /// @notice Role required for emergency operations
    bytes32 public constant EMERGENCY_ROLE = keccak256("EMERGENCY_ROLE");

    /// @notice Role for strategy admin operations (reserved for future use)
    bytes32 public constant STRATEGY_ADMIN_ROLE = keccak256("STRATEGY_ADMIN_ROLE");

    // ============================================
    // CONSTANTS
    // ============================================

    /// @notice Basis points denominator (10000 = 100%)
    uint256 public constant BASIS_POINTS = 10000;

    /// @notice Maximum number of approved adapters
    uint256 public constant MAX_ADAPTERS = 10;

    /// @notice Minimum rebalance interval (1 hour)
    uint256 public constant MIN_REBALANCE_INTERVAL = 1 hours;

    /// @notice Maximum rebalance interval (30 days)
    uint256 public constant MAX_REBALANCE_INTERVAL = 30 days;

    // ============================================
    // STATE VARIABLES
    // ============================================

    /// @notice Vault being managed (immutable for gas efficiency)
    GiveVault4626 public immutable vault;

    /// @notice Strategy registry for validation
    StrategyRegistry public immutable strategyRegistry;

    /// @notice Campaign registry for validation
    CampaignRegistry public immutable campaignRegistry;

    /// @notice Mapping of approved adapters
    mapping(address => bool) public approvedAdapters;

    /// @notice Array of adapter addresses (for iteration)
    address[] public adapterList;

    /// @notice Rebalance interval in seconds (default: 24 hours)
    uint256 public rebalanceInterval = 24 hours;

    /// @notice Timestamp of last rebalance
    uint256 public lastRebalanceTime;

    /// @notice Emergency exit threshold in basis points (default: 10%)
    uint256 public emergencyExitThreshold = 1000;

    /// @notice Whether auto-rebalancing is enabled (default: true)
    bool public autoRebalanceEnabled = true;

    /// @notice Whether emergency mode is active
    bool public emergencyMode;

    // ============================================
    // EVENTS
    // ============================================

    /**
     * @notice Emitted when adapter approval status changes
     * @param adapter Adapter address
     * @param approved Whether adapter is approved
     */
    event AdapterApproved(address indexed adapter, bool approved);

    /**
     * @notice Emitted when active adapter is changed
     * @param adapter New active adapter address
     */
    event AdapterActivated(address indexed adapter);

    /**
     * @notice Emitted when rebalance interval is updated
     * @param oldInterval Previous interval
     * @param newInterval New interval
     */
    event RebalanceIntervalUpdated(uint256 oldInterval, uint256 newInterval);

    /**
     * @notice Emitted when emergency threshold is updated
     * @param oldThreshold Previous threshold
     * @param newThreshold New threshold
     */
    event EmergencyThresholdUpdated(uint256 oldThreshold, uint256 newThreshold);

    /**
     * @notice Emitted when auto-rebalance is toggled
     * @param enabled Whether auto-rebalance is enabled
     */
    event AutoRebalanceToggled(bool enabled);

    /**
     * @notice Emitted when emergency mode is activated/deactivated
     * @param activated Whether emergency mode is active
     */
    event EmergencyModeActivated(bool activated);

    /**
     * @notice Emitted when strategy is rebalanced
     * @param oldAdapter Previous adapter
     * @param newAdapter New adapter
     */
    event StrategyRebalanced(address indexed oldAdapter, address indexed newAdapter);

    /**
     * @notice Emitted when vault parameters are updated
     * @param cashBufferBps Cash buffer in basis points
     * @param slippageBps Slippage tolerance in basis points
     * @param maxLossBps Maximum loss tolerance in basis points
     */
    event ParametersUpdated(uint256 cashBufferBps, uint256 slippageBps, uint256 maxLossBps);

    // ============================================
    // CONSTRUCTOR
    // ============================================

    /**
     * @notice Constructs a StrategyManager for a specific vault
     * @dev Grants all roles to admin, sets immutable vault reference.
     *      Initializes last rebalance time to deployment.
     * @param _vault Vault address to manage
     * @param _admin Admin address (receives all roles)
     * @param _strategyRegistry Strategy registry for validation
     * @param _campaignRegistry Campaign registry for validation
     */
    constructor(address _vault, address _admin, address _strategyRegistry, address _campaignRegistry) {
        if (_vault == address(0) || _admin == address(0)) {
            revert GiveErrors.ZeroAddress();
        }

        vault = GiveVault4626(payable(_vault));
        strategyRegistry = StrategyRegistry(_strategyRegistry);
        campaignRegistry = CampaignRegistry(_campaignRegistry);

        _grantRole(DEFAULT_ADMIN_ROLE, _admin);
        _grantRole(STRATEGY_MANAGER_ROLE, _admin);
        _grantRole(EMERGENCY_ROLE, _admin);
        _grantRole(STRATEGY_ADMIN_ROLE, _admin);

        lastRebalanceTime = block.timestamp;
    }

    // ============================================
    // ADAPTER MANAGEMENT
    // ============================================

    /**
     * @notice Approves or disapproves an adapter for use
     * @dev Adds to adapterList when approved, removes when disapproved.
     *      Maximum MAX_ADAPTERS can be approved.
     * @param adapter Adapter address
     * @param approved Whether to approve the adapter
     */
    function setAdapterApproval(address adapter, bool approved) external onlyRole(STRATEGY_MANAGER_ROLE) {
        if (adapter == address(0)) revert GiveErrors.ZeroAddress();

        bool wasApproved = approvedAdapters[adapter];
        approvedAdapters[adapter] = approved;

        if (approved && !wasApproved) {
            if (adapterList.length >= MAX_ADAPTERS) {
                revert GiveErrors.ParameterOutOfRange();
            }
            adapterList.push(adapter);
        } else if (!approved && wasApproved) {
            _removeFromAdapterList(adapter);
        }

        emit AdapterApproved(adapter, approved);
    }

    /**
     * @notice Sets the active adapter for the vault
     * @dev Validates adapter is approved and matches campaign strategy.
     *      Resets last rebalance time.
     * @param adapter Adapter to activate (address(0) to deactivate)
     */
    function setActiveAdapter(address adapter) external onlyRole(STRATEGY_MANAGER_ROLE) whenNotPaused {
        if (adapter != address(0)) {
            if (!approvedAdapters[adapter]) revert GiveErrors.InvalidAdapter();
            _assertAdapterMatchesCampaign(adapter);
        }
        vault.setActiveAdapter(IYieldAdapter(adapter));
        lastRebalanceTime = block.timestamp;

        emit AdapterActivated(adapter);
    }

    // ============================================
    // PARAMETER MANAGEMENT
    // ============================================

    /**
     * @notice Updates vault parameters in batch
     * @dev Calls vault setters for each parameter.
     * @param cashBufferBps Cash buffer percentage in basis points
     * @param slippageBps Slippage tolerance in basis points
     * @param maxLossBps Maximum loss tolerance in basis points
     */
    function updateVaultParameters(uint256 cashBufferBps, uint256 slippageBps, uint256 maxLossBps)
        external
        onlyRole(STRATEGY_MANAGER_ROLE)
    {
        vault.setCashBufferBps(cashBufferBps);
        vault.setSlippageBps(slippageBps);
        vault.setMaxLossBps(maxLossBps);

        emit ParametersUpdated(cashBufferBps, slippageBps, maxLossBps);
    }

    /**
     * @notice Sets the donation router for the vault
     * @dev Delegates to vault.setDonationRouter()
     * @param router Donation router address
     */
    function setDonationRouter(address router) external onlyRole(STRATEGY_MANAGER_ROLE) {
        vault.setDonationRouter(router);
    }

    // ============================================
    // REBALANCING
    // ============================================

    /**
     * @notice Sets the rebalance interval
     * @dev Must be between MIN_REBALANCE_INTERVAL and MAX_REBALANCE_INTERVAL
     * @param interval New interval in seconds
     */
    function setRebalanceInterval(uint256 interval) external onlyRole(STRATEGY_MANAGER_ROLE) {
        if (interval < MIN_REBALANCE_INTERVAL || interval > MAX_REBALANCE_INTERVAL) {
            revert GiveErrors.ParameterOutOfRange();
        }

        uint256 oldInterval = rebalanceInterval;
        rebalanceInterval = interval;

        emit RebalanceIntervalUpdated(oldInterval, interval);
    }

    /**
     * @notice Toggles auto-rebalancing
     * @dev When enabled, checkAndRebalance() can trigger automatic rebalancing
     * @param enabled Whether auto-rebalancing is enabled
     */
    function setAutoRebalanceEnabled(bool enabled) external onlyRole(STRATEGY_MANAGER_ROLE) {
        autoRebalanceEnabled = enabled;
        emit AutoRebalanceToggled(enabled);
    }

    /**
     * @notice Manually triggers a rebalance to the best performing adapter
     * @dev Finds best adapter and switches if different from current.
     *      Reverts if paused.
     */
    function rebalance() external onlyRole(STRATEGY_MANAGER_ROLE) whenNotPaused {
        _performRebalance();
    }

    /**
     * @notice Checks if rebalancing is needed and performs it if conditions met
     * @dev Public function, can be called by anyone (e.g., keeper bots).
     *      Requires: auto-rebalance enabled, not in emergency mode, interval elapsed.
     */
    function checkAndRebalance() external {
        if (!autoRebalanceEnabled || emergencyMode) return;
        if (block.timestamp < lastRebalanceTime + rebalanceInterval) return;

        _performRebalance();
    }

    // ============================================
    // EMERGENCY FUNCTIONS
    // ============================================

    /**
     * @notice Sets the emergency exit threshold
     * @dev Maximum allowed threshold is 50% (5000 basis points)
     * @param threshold Loss threshold in basis points
     */
    function setEmergencyExitThreshold(uint256 threshold) external onlyRole(STRATEGY_MANAGER_ROLE) {
        if (threshold > 5000) revert GiveErrors.ParameterOutOfRange(); // Max 50%

        uint256 oldThreshold = emergencyExitThreshold;
        emergencyExitThreshold = threshold;

        emit EmergencyThresholdUpdated(oldThreshold, threshold);
    }

    /**
     * @notice Activates emergency mode
     * @dev Pauses vault operations and disables auto-rebalancing
     */
    function activateEmergencyMode() external onlyRole(EMERGENCY_ROLE) {
        emergencyMode = true;
        vault.emergencyPause();

        emit EmergencyModeActivated(true);
    }

    /**
     * @notice Deactivates emergency mode
     * @dev Requires DEFAULT_ADMIN_ROLE (higher authority than EMERGENCY_ROLE)
     */
    function deactivateEmergencyMode() external onlyRole(DEFAULT_ADMIN_ROLE) {
        emergencyMode = false;
        emit EmergencyModeActivated(false);
    }

    /**
     * @notice Emergency withdrawal from current adapter
     * @dev Withdraws all assets from active adapter back to vault
     * @return withdrawn Amount withdrawn
     */
    function emergencyWithdraw() external onlyRole(EMERGENCY_ROLE) returns (uint256 withdrawn) {
        withdrawn = vault.emergencyWithdrawFromAdapter();
    }

    // ============================================
    // PAUSE CONTROLS
    // ============================================

    /**
     * @notice Pauses/unpauses vault investing
     * @dev Prevents new investments into adapter when paused
     * @param paused Whether invest should be paused
     */
    function setInvestPaused(bool paused) external onlyRole(EMERGENCY_ROLE) {
        vault.setInvestPaused(paused);
    }

    /**
     * @notice Pauses/unpauses vault harvesting
     * @dev Prevents yield harvesting when paused
     * @param paused Whether harvest should be paused
     */
    function setHarvestPaused(bool paused) external onlyRole(EMERGENCY_ROLE) {
        vault.setHarvestPaused(paused);
    }

    // ============================================
    // INTERNAL FUNCTIONS
    // ============================================

    /**
     * @notice Performs the actual rebalancing logic
     * @dev Finds best adapter and switches if different from current.
     *      Updates lastRebalanceTime on successful rebalance.
     */
    function _performRebalance() internal {
        address currentAdapter = address(vault.activeAdapter());
        address bestAdapter = _findBestAdapter();

        if (bestAdapter != currentAdapter && bestAdapter != address(0)) {
            vault.setActiveAdapter(IYieldAdapter(bestAdapter));
            lastRebalanceTime = block.timestamp;

            emit StrategyRebalanced(currentAdapter, bestAdapter);
        }
    }

    /**
     * @notice Finds the best performing approved adapter
     * @dev Simple heuristic: adapter with most assets is "best".
     *      In production, this would use more sophisticated yield calculations.
     * @return Best adapter address (or address(0) if none found)
     */
    function _findBestAdapter() internal view returns (address) {
        uint256 len = adapterList.length;
        if (len == 0) return address(0);

        address bestAdapter = adapterList[0];
        uint256 bestYield = 0;

        for (uint256 i = 0; i < len; i++) {
            address adapter = adapterList[i];
            if (!approvedAdapters[adapter]) continue;

            // Simple heuristic: adapter with most assets is "best"
            // In production, this would use more sophisticated yield calculations
            try IYieldAdapter(adapter).totalAssets() returns (uint256 assets) {
                if (assets > bestYield) {
                    bestYield = assets;
                    bestAdapter = adapter;
                }
            } catch {
                // Skip adapters that fail
                continue;
            }
        }

        return bestAdapter;
    }

    /**
     * @notice Validates adapter matches campaign's strategy
     * @dev Checks that adapter matches the strategy assigned to campaign.
     *      Skips validation if no campaign assigned.
     * @param adapter Adapter address to validate
     */
    function _assertAdapterMatchesCampaign(address adapter) internal view {
        bytes32 campaignId = StorageLib.getVaultCampaign(address(vault));
        if (campaignId == bytes32(0)) return; // No campaign assigned yet

        GiveTypes.CampaignConfig memory campaign = campaignRegistry.getCampaign(campaignId);
        GiveTypes.StrategyConfig memory strategy = strategyRegistry.getStrategy(campaign.strategyId);

        if (strategy.adapter != adapter) {
            revert GiveErrors.InvalidStrategy();
        }
    }

    /**
     * @notice Removes an adapter from the list using swap-and-pop
     * @dev O(n) search, O(1) removal
     * @param adapter Adapter to remove
     */
    function _removeFromAdapterList(address adapter) internal {
        for (uint256 i = 0; i < adapterList.length; i++) {
            if (adapterList[i] == adapter) {
                adapterList[i] = adapterList[adapterList.length - 1];
                adapterList.pop();
                break;
            }
        }
    }

    // ============================================
    // VIEW FUNCTIONS
    // ============================================

    /**
     * @notice Returns the list of approved adapters
     * @dev Filters adapterList to only include currently approved adapters
     * @return Array of approved adapter addresses
     */
    function getApprovedAdapters() external view returns (address[] memory) {
        uint256 len = adapterList.length;
        address[] memory approved = new address[](len);
        uint256 count = 0;

        for (uint256 i = 0; i < len; i++) {
            if (approvedAdapters[adapterList[i]]) {
                approved[count] = adapterList[i];
                count++;
            }
        }

        // Resize array to actual count
        assembly {
            mstore(approved, count)
        }

        return approved;
    }

    /**
     * @notice Returns strategy configuration
     * @dev Aggregates multiple configuration values into single call
     * @return rebalanceIntervalValue Rebalance interval in seconds
     * @return emergencyThreshold Emergency exit threshold in basis points
     * @return autoRebalance Whether auto-rebalance is enabled
     * @return emergency Whether emergency mode is active
     * @return lastRebalance Timestamp of last rebalance
     */
    function getConfiguration()
        external
        view
        returns (
            uint256 rebalanceIntervalValue,
            uint256 emergencyThreshold,
            bool autoRebalance,
            bool emergency,
            uint256 lastRebalance
        )
    {
        return (rebalanceInterval, emergencyExitThreshold, autoRebalanceEnabled, emergencyMode, lastRebalanceTime);
    }

    /**
     * @notice Checks if rebalancing is due
     * @dev Useful for keeper bots to determine if checkAndRebalance() should be called
     * @return Whether rebalancing should occur
     */
    function isRebalanceDue() external view returns (bool) {
        return autoRebalanceEnabled && !emergencyMode && block.timestamp >= lastRebalanceTime + rebalanceInterval;
    }
}
