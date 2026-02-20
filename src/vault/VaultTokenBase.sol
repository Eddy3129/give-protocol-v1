// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";

import "../interfaces/IACLManager.sol";
import "../storage/StorageLib.sol";
import "../types/GiveTypes.sol";

/**
 * @title VaultTokenBase
 * @author GIVE Labs
 * @notice Base contract for UUPS-upgradeable vault implementations with unique storage per instance
 * @dev Provides shared helpers for vault implementations using Diamond Storage pattern.
 *      Critical fix for C-01: Removes immutable _vaultId to prevent storage collision across proxies.
 *
 *      Key Changes from v0.5:
 *      - ❌ REMOVED: `bytes32 internal immutable _vaultId` (caused storage collision)
 *      - ✅ ADDED: Storage-based `_vaultId` computed per proxy instance
 *      - ✅ ADDED: Internal initializer pattern for UUPS compatibility
 *      - ✅ ADDED: AccessControlUpgradeable for local role management
 *      - ✅ ADDED: ACL manager delegation for protocol-wide role checks
 *
 *      Storage Safety:
 *      - Each proxy computes unique vaultId = keccak256(address(this))
 *      - Vault config stored at StorageLib.vault(vaultId) → unique slot per proxy
 *      - No shared state between vault instances
 *
 *      C-01 Fix Explanation:
 *      In v0.5, immutable _vaultId was set in constructor. EIP-1167 clones copied
 *      this value from implementation, causing all clones to share same vaultId.
 *      This led to storage collision when multiple vaults wrote to StorageLib.vault(_vaultId).
 *      Now each proxy computes vaultId during initialization using its own address.
 *
 *      Role Model:
 *      - Inherits AccessControlUpgradeable for local role storage (DEFAULT_ADMIN_ROLE, etc.)
 *      - Delegates role checks to external ACL manager (if set) for protocol-wide roles
 *      - _checkRole() tries ACL manager first, falls back to local roles
 */
abstract contract VaultTokenBase is
    Initializable,
    AccessControlUpgradeable,
    ReentrancyGuardUpgradeable,
    PausableUpgradeable
{
    // ============================================
    // STATE VARIABLES
    // ============================================

    /**
     * @notice ACL manager for protocol-wide role delegation
     * @dev Set during initialization. Role checks first try ACL manager, then local roles.
     */
    IACLManager public aclManager;

    /**
     * @notice Unique identifier for this vault instance
     * @dev Computed as keccak256(address(this)) during initialization.
     *      Each proxy has unique address → unique vaultId → unique storage slot.
     *      Stored in proxy storage to survive upgrades.
     */
    bytes32 private _vaultId;

    // ============================================
    // EVENTS
    // ============================================

    /// @notice Emitted when ACL manager is updated
    event ACLManagerUpdated(address indexed previousManager, address indexed newManager);

    // ============================================
    // ERRORS
    // ============================================

    /// @notice Vault ID already initialized
    error VaultIdAlreadySet();

    /// @notice Zero address provided where not allowed
    error ZeroAddress();

    // ============================================
    // INITIALIZATION
    // ============================================

    /**
     * @notice Internal initializer for VaultTokenBase
     * @dev Called by inheriting contracts during their initialization.
     *      Sets vaultId once based on proxy address.
     *      Must be called exactly once per proxy instance.
     * @param acl Address of ACLManager contract
     */
    function __VaultTokenBase_init(address acl) internal onlyInitializing {
        if (acl == address(0)) revert ZeroAddress();

        __AccessControl_init();
        __ReentrancyGuard_init();
        __Pausable_init();

        // Compute unique vault ID based on this proxy's address
        // Each proxy has unique address → unique vaultId → unique storage
        bytes32 computedId = keccak256(abi.encodePacked(address(this)));

        // Guard against re-initialization (should never happen due to initializer modifier)
        if (_vaultId != bytes32(0)) revert VaultIdAlreadySet();

        _vaultId = computedId;
        aclManager = IACLManager(acl);
    }

    // ============================================
    // PUBLIC VIEW FUNCTIONS
    // ============================================

    /**
     * @notice Returns this vault's unique identifier
     * @dev Used as key for Diamond Storage lookups.
     *      Each proxy returns its own unique ID.
     * @return Unique vault identifier
     */
    function vaultId() public view returns (bytes32) {
        return _vaultId;
    }

    // ============================================
    // INTERNAL FUNCTIONS
    // ============================================

    /**
     * @notice Returns storage reference for this vault's configuration
     * @dev Uses Diamond Storage pattern via StorageLib.
     *      Each vault's unique vaultId ensures isolated storage.
     * @return cfg Vault configuration storage reference
     */
    function _vaultConfig() internal view returns (GiveTypes.VaultConfig storage cfg) {
        return StorageLib.vault(_vaultId);
    }

    /**
     * @notice Override role check to delegate to ACL manager
     * @dev Implements dual-source role checking:
     *      1. First checks external ACL manager (if set and account has role)
     *      2. Falls back to local AccessControl storage
     *      This allows vaults to respect both protocol-wide roles and vault-specific roles.
     * @param role The role identifier to check
     * @param account The address to verify
     */
    function _checkRole(bytes32 role, address account) internal view override {
        // Try ACL manager first if available
        if (address(aclManager) != address(0) && aclManager.hasRole(role, account)) {
            return;
        }
        // Fall back to local role storage
        super._checkRole(role, account);
    }
}
