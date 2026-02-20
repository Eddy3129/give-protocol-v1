// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "../interfaces/IACLManager.sol";

/**
 * @title ACLManager
 * @author GIVE Labs
 * @notice Centralised role registry with propose/accept admin flow and upgrade gating (UUPS)
 * @dev Stores role membership in contract storage so it can serve AccessControl-aware contracts directly.
 *      Shared ACL components call `hasRole` to defer role checks to this registry while keeping backwards compatibility.
 *
 *      Key Features:
 *      - Dynamic role creation and management
 *      - Two-step admin transfers for safety
 *      - Efficient member enumeration with swap-and-pop
 *      - UUPS upgradeability gated by ROLE_UPGRADER
 *      - 8 canonical protocol roles predefined
 *
 *      Security Model:
 *      - ROLE_SUPER_ADMIN is required for all role admins
 *      - Role admins can grant/revoke their role to any address
 *      - Super admins can override any role admin action
 *      - Two-step transfer prevents accidental admin loss
 */
contract ACLManager is Initializable, UUPSUpgradeable, IACLManager {
    // ============================================
    // STRUCTS
    // ============================================

    /**
     * @notice Internal storage for role data
     * @dev Uses efficient enumeration pattern with swap-and-pop
     */
    struct RoleData {
        address admin; // Current admin for this role
        address pendingAdmin; // Proposed admin (two-step transfer)
        bool exists; // Whether role has been created
        address[] members; // Enumerable list of members
        mapping(address => bool) isMember; // Quick membership check
        mapping(address => uint256) indexPlusOne; // Index+1 in members array (enables swap-and-pop)
    }

    // ============================================
    // CONSTANTS - CANONICAL ROLES
    // ============================================

    /**
     * @notice Super admin role - top-level administrator
     * @dev Can create roles, manage all roles, required for all admins
     */
    bytes32 public constant ROLE_SUPER_ADMIN = keccak256("ROLE_SUPER_ADMIN");

    /**
     * @notice Upgrader role - authorized to upgrade UUPS contracts
     * @dev Required by _authorizeUpgrade hook
     */
    bytes32 public constant ROLE_UPGRADER = keccak256("ROLE_UPGRADER");

    /**
     * @notice Protocol admin role - global protocol settings
     * @dev Manages protocol-wide parameters (fees, treasury, etc.)
     */
    bytes32 public constant ROLE_PROTOCOL_ADMIN = keccak256("ROLE_PROTOCOL_ADMIN");

    /**
     * @notice Strategy admin role - yield strategy management
     * @dev Can create/update/deprecate yield strategies
     */
    bytes32 public constant ROLE_STRATEGY_ADMIN = keccak256("ROLE_STRATEGY_ADMIN");

    /**
     * @notice Campaign admin role - campaign lifecycle management
     * @dev Can approve/reject/pause campaigns
     */
    bytes32 public constant ROLE_CAMPAIGN_ADMIN = keccak256("ROLE_CAMPAIGN_ADMIN");

    /**
     * @notice Campaign creator role - reserved for future gating of campaign submissions
     * @dev Currently not enforced; anyone can submit campaigns with deposit
     */
    bytes32 public constant ROLE_CAMPAIGN_CREATOR = keccak256("ROLE_CAMPAIGN_CREATOR");

    /**
     * @notice Campaign curator role - assigned to manage specific campaigns
     * @dev Curators manage day-to-day operations of their campaigns
     */
    bytes32 public constant ROLE_CAMPAIGN_CURATOR = keccak256("ROLE_CAMPAIGN_CURATOR");

    /**
     * @notice Checkpoint council role - checkpoint management
     * @dev Can schedule and finalize checkpoints for voting
     */
    bytes32 public constant ROLE_CHECKPOINT_COUNCIL = keccak256("ROLE_CHECKPOINT_COUNCIL");

    // ============================================
    // STATE VARIABLES
    // ============================================

    /**
     * @notice Mapping of role IDs to role data
     * @dev Contains all role information including admins and members
     */
    mapping(bytes32 => RoleData) private _roles;

    // ============================================
    // ERRORS
    // ============================================

    /// @notice Zero address provided where non-zero required
    error ZeroAddress();

    /// @notice Role already exists and cannot be created again
    error RoleAlreadyExists(bytes32 roleId);

    /// @notice Role does not exist
    error RoleDoesNotExist(bytes32 roleId);

    /// @notice Caller is not authorized for this role operation
    error UnauthorizedRole(bytes32 roleId, address account);

    /// @notice No pending admin has been proposed for this role
    error PendingAdminMissing(bytes32 roleId);

    /// @notice Caller is not the pending admin
    error PendingAdminMismatch(bytes32 roleId, address expected, address actual);

    /// @notice Admin must hold ROLE_SUPER_ADMIN
    error AdminMustBeSuper(bytes32 roleId, address admin);

    // ============================================
    // MODIFIERS
    // ============================================

    /**
     * @notice Restricts access to super admins only
     * @dev Reverts if caller does not hold ROLE_SUPER_ADMIN
     */
    modifier onlySuperAdmin() {
        if (!hasRole(ROLE_SUPER_ADMIN, msg.sender)) {
            revert UnauthorizedRole(ROLE_SUPER_ADMIN, msg.sender);
        }
        _;
    }

    /**
     * @notice Restricts access to role admin or super admin
     * @dev Reverts if caller is not the role's admin or a super admin
     * @param roleId The role to check admin privileges for
     */
    modifier onlyRoleAdmin(bytes32 roleId) {
        RoleData storage role = _roles[roleId];
        if (!role.exists) revert RoleDoesNotExist(roleId);
        address admin = role.admin;
        if (msg.sender != admin && !hasRole(ROLE_SUPER_ADMIN, msg.sender)) {
            revert UnauthorizedRole(roleId, msg.sender);
        }
        _;
    }

    // ============================================
    // INITIALIZATION
    // ============================================

    /**
     * @notice Initializes the ACL manager
     * @dev Sets up ROLE_SUPER_ADMIN, ROLE_UPGRADER, and all canonical roles.
     *      Only callable once due to initializer modifier.
     * @param initialSuperAdmin Address to receive super admin role
     * @param upgrader Address authorized to upgrade contracts
     */
    function initialize(address initialSuperAdmin, address upgrader) external initializer {
        if (initialSuperAdmin == address(0) || upgrader == address(0)) revert ZeroAddress();

        // Create and grant super admin role
        _createRole(ROLE_SUPER_ADMIN, initialSuperAdmin, false);
        _grantRole(ROLE_SUPER_ADMIN, initialSuperAdmin);

        // Create and grant upgrader role
        _createRole(ROLE_UPGRADER, initialSuperAdmin, false);
        _grantRole(ROLE_UPGRADER, upgrader);

        // Create all canonical protocol roles
        _createCanonicalRoles(initialSuperAdmin);
    }

    // ============================================
    // EXTERNAL FUNCTIONS - ROLE MANAGEMENT
    // ============================================

    /**
     * @notice Creates a new role managed by the ACL
     * @dev Only callable by super admin. Role admin must also be a super admin.
     * @param roleId The unique identifier for the role
     * @param admin The address that will administer this role
     */
    function createRole(bytes32 roleId, address admin) external onlySuperAdmin {
        if (admin == address(0)) revert ZeroAddress();
        if (!hasRole(ROLE_SUPER_ADMIN, admin)) {
            revert AdminMustBeSuper(roleId, admin);
        }
        _createRole(roleId, admin, true);
    }

    /**
     * @notice Grants a role to an account
     * @dev Only callable by the role's admin or super admin
     * @param roleId The role identifier
     * @param account The address to receive the role
     */
    function grantRole(bytes32 roleId, address account) external onlyRoleAdmin(roleId) {
        if (account == address(0)) revert ZeroAddress();
        _grantRole(roleId, account);
    }

    /**
     * @notice Revokes a role from an account
     * @dev Only callable by the role's admin or super admin
     * @param roleId The role identifier
     * @param account The address to lose the role
     */
    function revokeRole(bytes32 roleId, address account) external onlyRoleAdmin(roleId) {
        if (account == address(0)) revert ZeroAddress();
        _revokeRole(roleId, account);
    }

    /**
     * @notice Proposes a new admin for a role (step 1 of 2)
     * @dev Only callable by current role admin. New admin must be super admin.
     * @param roleId The role identifier
     * @param newAdmin The proposed new admin address
     */
    function proposeRoleAdmin(bytes32 roleId, address newAdmin) external onlyRoleAdmin(roleId) {
        if (newAdmin == address(0)) revert ZeroAddress();
        if (!hasRole(ROLE_SUPER_ADMIN, newAdmin)) {
            revert AdminMustBeSuper(roleId, newAdmin);
        }

        RoleData storage role = _roles[roleId];
        role.pendingAdmin = newAdmin;

        emit RoleAdminProposed(roleId, role.admin, newAdmin);
    }

    /**
     * @notice Accepts a pending admin proposal (step 2 of 2)
     * @dev Only callable by the proposed admin. Completes admin transfer.
     * @param roleId The role identifier
     */
    function acceptRoleAdmin(bytes32 roleId) external {
        RoleData storage role = _roles[roleId];
        if (!role.exists) revert RoleDoesNotExist(roleId);

        address pending = role.pendingAdmin;
        if (pending == address(0)) revert PendingAdminMissing(roleId);
        if (pending != msg.sender) {
            revert PendingAdminMismatch(roleId, pending, msg.sender);
        }
        if (!hasRole(ROLE_SUPER_ADMIN, msg.sender)) {
            revert AdminMustBeSuper(roleId, msg.sender);
        }

        address previousAdmin = role.admin;
        role.admin = msg.sender;
        role.pendingAdmin = address(0);

        emit RoleAdminAccepted(roleId, previousAdmin, msg.sender);
    }

    // ============================================
    // EXTERNAL VIEW FUNCTIONS
    // ============================================

    /**
     * @notice Checks if an account has a specific role
     * @param roleId The role identifier to check
     * @param account The address to check
     * @return True if account has the role, false otherwise
     */
    function hasRole(bytes32 roleId, address account) public view returns (bool) {
        RoleData storage role = _roles[roleId];
        if (!role.exists) return false;
        return role.isMember[account];
    }

    /**
     * @notice Returns the admin address for a role
     * @param roleId The role identifier
     * @return The address that administers this role (address(0) if role doesn't exist)
     */
    function roleAdmin(bytes32 roleId) public view returns (address) {
        RoleData storage role = _roles[roleId];
        if (!role.exists) return address(0);
        return role.admin;
    }

    /**
     * @notice Returns all members of a role
     * @dev Reverts if role does not exist
     * @param roleId The role identifier
     * @return Array of addresses holding the role
     */
    function getRoleMembers(bytes32 roleId) external view returns (address[] memory) {
        RoleData storage role = _roles[roleId];
        if (!role.exists) revert RoleDoesNotExist(roleId);
        return role.members;
    }

    /**
     * @notice Checks if a role exists
     * @param roleId The role identifier
     * @return True if role exists, false otherwise
     */
    function roleExists(bytes32 roleId) external view returns (bool) {
        return _roles[roleId].exists;
    }

    /**
     * @notice Returns all canonical protocol role identifiers
     * @dev These are the predefined roles used across the protocol
     * @return roles Array of canonical role identifiers
     */
    function canonicalRoles() external pure returns (bytes32[] memory roles) {
        roles = new bytes32[](8);
        roles[0] = ROLE_SUPER_ADMIN;
        roles[1] = ROLE_UPGRADER;
        roles[2] = ROLE_PROTOCOL_ADMIN;
        roles[3] = ROLE_STRATEGY_ADMIN;
        roles[4] = ROLE_CAMPAIGN_ADMIN;
        roles[5] = ROLE_CAMPAIGN_CREATOR;
        roles[6] = ROLE_CAMPAIGN_CURATOR;
        roles[7] = ROLE_CHECKPOINT_COUNCIL;
    }

    /**
     * @notice Checks if a role is canonical
     * @param roleId The role identifier to check
     * @return True if role is canonical, false otherwise
     */
    function isCanonicalRole(bytes32 roleId) public pure returns (bool) {
        return roleId == ROLE_SUPER_ADMIN || roleId == ROLE_UPGRADER || roleId == ROLE_PROTOCOL_ADMIN
            || roleId == ROLE_STRATEGY_ADMIN || roleId == ROLE_CAMPAIGN_ADMIN || roleId == ROLE_CAMPAIGN_CREATOR
            || roleId == ROLE_CAMPAIGN_CURATOR || roleId == ROLE_CHECKPOINT_COUNCIL;
    }

    // ============================================
    // CANONICAL ROLE GETTERS
    // ============================================

    /// @notice Returns the protocol admin role identifier
    function protocolAdminRole() external pure returns (bytes32) {
        return ROLE_PROTOCOL_ADMIN;
    }

    /// @notice Returns the strategy admin role identifier
    function strategyAdminRole() external pure returns (bytes32) {
        return ROLE_STRATEGY_ADMIN;
    }

    /// @notice Returns the campaign admin role identifier
    function campaignAdminRole() external pure returns (bytes32) {
        return ROLE_CAMPAIGN_ADMIN;
    }

    /// @notice Returns the campaign creator role identifier
    function campaignCreatorRole() external pure returns (bytes32) {
        return ROLE_CAMPAIGN_CREATOR;
    }

    /// @notice Returns the campaign curator role identifier
    function campaignCuratorRole() external pure returns (bytes32) {
        return ROLE_CAMPAIGN_CURATOR;
    }

    /// @notice Returns the checkpoint council role identifier
    function checkpointCouncilRole() external pure returns (bytes32) {
        return ROLE_CHECKPOINT_COUNCIL;
    }

    // ============================================
    // INTERNAL FUNCTIONS
    // ============================================

    /**
     * @notice Internal function to create a role
     * @dev Stores role data and emits RoleCreated event
     * @param roleId The role identifier
     * @param admin The address that will administer this role
     * @param checkExists Whether to check if admin is super admin
     */
    function _createRole(bytes32 roleId, address admin, bool checkExists) internal {
        RoleData storage role = _roles[roleId];
        if (role.exists) revert RoleAlreadyExists(roleId);

        if (checkExists && !hasRole(ROLE_SUPER_ADMIN, admin)) {
            revert AdminMustBeSuper(roleId, admin);
        }

        role.admin = admin;
        role.exists = true;

        emit RoleCreated(roleId, admin, msg.sender);
    }

    /**
     * @notice Internal function to grant a role
     * @dev Adds account to members array and updates mappings. Idempotent.
     * @param roleId The role identifier
     * @param account The address to receive the role
     */
    function _grantRole(bytes32 roleId, address account) internal {
        RoleData storage role = _roles[roleId];
        if (!role.exists) revert RoleDoesNotExist(roleId);
        if (role.isMember[account]) return; // Already has role

        role.isMember[account] = true;
        role.members.push(account);
        role.indexPlusOne[account] = role.members.length; // Store index + 1

        emit RoleGranted(roleId, account, msg.sender);
    }

    /**
     * @notice Internal function to revoke a role
     * @dev Removes account from members array using swap-and-pop. Idempotent.
     * @param roleId The role identifier
     * @param account The address to lose the role
     */
    function _revokeRole(bytes32 roleId, address account) internal {
        RoleData storage role = _roles[roleId];
        if (!role.exists) revert RoleDoesNotExist(roleId);
        if (!role.isMember[account]) return; // Doesn't have role

        uint256 index = role.indexPlusOne[account];
        if (index != 0) {
            // Swap-and-pop optimization
            uint256 lastIndex = role.members.length;
            if (index != lastIndex) {
                address lastMember = role.members[lastIndex - 1];
                role.members[index - 1] = lastMember;
                role.indexPlusOne[lastMember] = index;
            }
            role.members.pop();
            role.indexPlusOne[account] = 0;
        }

        role.isMember[account] = false;

        emit RoleRevoked(roleId, account, msg.sender);
    }

    /**
     * @notice Creates all canonical protocol roles
     * @dev Called during initialization to set up standard roles
     * @param initialSuperAdmin Address to receive all canonical roles initially
     */
    function _createCanonicalRoles(address initialSuperAdmin) private {
        _createRole(ROLE_PROTOCOL_ADMIN, initialSuperAdmin, false);
        _grantRole(ROLE_PROTOCOL_ADMIN, initialSuperAdmin);

        _createRole(ROLE_STRATEGY_ADMIN, initialSuperAdmin, false);
        _grantRole(ROLE_STRATEGY_ADMIN, initialSuperAdmin);

        _createRole(ROLE_CAMPAIGN_ADMIN, initialSuperAdmin, false);
        _grantRole(ROLE_CAMPAIGN_ADMIN, initialSuperAdmin);

        _createRole(ROLE_CAMPAIGN_CREATOR, initialSuperAdmin, false);
        _grantRole(ROLE_CAMPAIGN_CREATOR, initialSuperAdmin);

        _createRole(ROLE_CAMPAIGN_CURATOR, initialSuperAdmin, false);
        _grantRole(ROLE_CAMPAIGN_CURATOR, initialSuperAdmin);

        _createRole(ROLE_CHECKPOINT_COUNCIL, initialSuperAdmin, false);
        _grantRole(ROLE_CHECKPOINT_COUNCIL, initialSuperAdmin);
    }

    // ============================================
    // UUPS UPGRADE AUTHORIZATION
    // ============================================

    /**
     * @notice UUPS upgrade authorization hook
     * @dev Only addresses with ROLE_UPGRADER can upgrade this contract
     * @param newImplementation Address of new implementation (unused but required by interface)
     */
    function _authorizeUpgrade(address newImplementation) internal view override {
        if (!hasRole(ROLE_UPGRADER, msg.sender)) {
            revert UnauthorizedRole(ROLE_UPGRADER, msg.sender);
        }
    }
}
