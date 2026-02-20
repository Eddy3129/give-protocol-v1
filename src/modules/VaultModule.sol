// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {StorageLib} from "../storage/StorageLib.sol";
import {GiveTypes} from "../types/GiveTypes.sol";

/**
 * @title VaultModule
 * @author GIVE Labs
 * @notice Library module for vault configuration and management
 * @dev Provides functions to configure vault metadata in protocol storage.
 *      Used by GiveProtocolCore to register and manage vault instances.
 *
 *      Key Responsibilities:
 *      - Register vault proxy and implementation addresses
 *      - Bind vaults to assets, adapters, and risk profiles
 *      - Configure vault operational parameters (buffers, slippage, loss tolerance)
 *      - Track vault active status
 *
 *      Architecture:
 *      - Pure library (no state, called via delegatecall from GiveProtocolCore)
 *      - Writes to diamond storage via StorageLib
 *      - Emits events from GiveProtocolCore context
 *
 *      Security Model:
 *      - Only GiveProtocolCore should call these functions
 *      - MANAGER_ROLE required in calling contract
 *      - Vault ID must be unique (handled by caller)
 *
 *      Use Cases:
 *      - Deploy new campaign vault → configure()
 *      - Query vault configuration → StorageLib.vault()
 *      - Update vault parameters → modify VaultConfig in storage directly
 */
library VaultModule {
    // ============================================
    // CONSTANTS
    // ============================================

    /// @notice Role required to manage vault configurations
    bytes32 public constant MANAGER_ROLE = keccak256("VAULT_MODULE_MANAGER_ROLE");

    // ============================================
    // STRUCTS
    // ============================================

    /**
     * @notice Input parameters for vault configuration
     * @param id Unique identifier for the vault (keccak256 of proxy address)
     * @param proxy Address of the vault proxy contract
     * @param implementation Address of the vault implementation contract
     * @param asset Underlying asset address (USDC, WETH, etc.)
     * @param adapterId ID of the yield adapter bound to this vault
     * @param donationModuleId ID of the donation configuration
     * @param riskId ID of the risk profile applied to this vault
     * @param cashBufferBps Percentage of assets to keep liquid (100 = 1%)
     * @param slippageBps Maximum allowed slippage on adapter operations (50 = 0.5%)
     * @param maxLossBps Maximum acceptable loss threshold (50 = 0.5%)
     */
    struct VaultConfigInput {
        bytes32 id;
        address proxy;
        address implementation;
        address asset;
        bytes32 adapterId;
        bytes32 donationModuleId;
        bytes32 riskId;
        uint16 cashBufferBps;
        uint16 slippageBps;
        uint16 maxLossBps;
    }

    // ============================================
    // EVENTS
    // ============================================

    /**
     * @notice Emitted when a vault is configured in the protocol
     * @param id Unique vault identifier
     * @param proxy Vault proxy address
     * @param implementation Vault implementation address
     * @param asset Underlying asset address
     */
    event VaultConfigured(bytes32 indexed id, address proxy, address implementation, address asset);

    // ============================================
    // FUNCTIONS
    // ============================================

    /**
     * @notice Configures a vault in protocol storage
     * @dev Writes vault configuration to diamond storage slot.
     *      Automatically sets vault as active.
     *      Does not validate addresses - caller must ensure validity.
     * @param vaultId Unique identifier for the vault
     * @param cfg Vault configuration parameters
     */
    function configure(bytes32 vaultId, VaultConfigInput memory cfg) internal {
        GiveTypes.VaultConfig storage info = StorageLib.vault(vaultId);
        info.id = vaultId;
        info.proxy = cfg.proxy;
        info.implementation = cfg.implementation;
        info.asset = cfg.asset;
        info.adapterId = cfg.adapterId;
        info.donationModuleId = cfg.donationModuleId;
        info.riskId = cfg.riskId;
        info.cashBufferBps = cfg.cashBufferBps;
        info.slippageBps = cfg.slippageBps;
        info.maxLossBps = cfg.maxLossBps;
        info.active = true;

        emit VaultConfigured(vaultId, cfg.proxy, cfg.implementation, cfg.asset);
    }
}
