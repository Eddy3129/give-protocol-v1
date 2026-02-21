// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";

import "../interfaces/IACLManager.sol";
import "../storage/StorageLib.sol";
import "../types/GiveTypes.sol";

/**
 * @title NGORegistry
 * @author GIVE Labs
 * @notice Canonical registry for verified NGO/charity organizations and donation tracking
 * @dev Manages NGO approval, verification, metadata, and cumulative donation records.
 *      Provides timelock mechanism for changing the protocol's current default NGO.
 *
 *      Key Features:
 *      - NGO approval with KYC verification and attestation
 *      - Off-chain metadata via IPFS CIDs
 *      - Cumulative donation tracking per NGO
 *      - Timelock protection for current NGO changes (24 hours)
 *      - Emergency admin override for current NGO
 *      - Pausable for emergency situations
 *      - UUPS upgradeability
 *
 *      NGO Lifecycle:
 *      1. Added → NGO_MANAGER adds NGO with metadata and KYC hash
 *      2. Active → NGO can receive donations via protocol
 *      3. Updated → Metadata or KYC hash can be updated (versioned)
 *      4. Removed → NGO marked inactive, removed from approved list
 *
 *      Current NGO System:
 *      - Protocol has one "current" NGO at a time (default recipient)
 *      - Changes require 24-hour timelock (propose → wait → execute)
 *      - Admin can emergency override timelock if needed
 *      - First NGO added automatically becomes current NGO
 *
 *      Security Model:
 *      - NGO_MANAGER can add, remove, update NGOs and propose current NGO changes
 *      - DONATION_RECORDER (vault contracts) can record donations
 *      - GUARDIAN can pause/unpause registry
 *      - PROTOCOL_ADMIN can emergency set current NGO (bypassing timelock)
 *      - ROLE_UPGRADER can upgrade contract
 */
contract NGORegistry is Initializable, UUPSUpgradeable, PausableUpgradeable {
    // ============================================
    // STATE VARIABLES
    // ============================================

    /**
     * @notice ACL manager for role-based access control
     * @dev All admin operations check roles via this contract
     */
    IACLManager public aclManager;

    /**
     * @notice Role identifier for NGO management operations
     * @dev Can add, remove, update NGOs and propose current NGO changes
     */
    bytes32 public constant NGO_MANAGER_ROLE = keccak256("NGO_MANAGER_ROLE");

    /**
     * @notice Role identifier for recording donations
     * @dev Typically granted to vault contracts that distribute yield to NGOs
     */
    bytes32 public constant DONATION_RECORDER_ROLE = keccak256("DONATION_RECORDER_ROLE");

    /**
     * @notice Role identifier for emergency pause operations
     * @dev Can pause/unpause registry in emergency situations
     */
    bytes32 public constant GUARDIAN_ROLE = keccak256("GUARDIAN_ROLE");

    /**
     * @notice Role identifier for contract upgrades
     * @dev Must match ACLManager.ROLE_UPGRADER
     */
    bytes32 public constant ROLE_UPGRADER = keccak256("ROLE_UPGRADER");

    /**
     * @notice Timelock delay for current NGO changes
     * @dev 24-hour delay provides transparency and safety for default NGO changes
     */
    uint256 public constant TIMELOCK_DELAY = 24 hours;

    // ============================================
    // EVENTS
    // ============================================

    /**
     * @notice Emitted when an NGO is approved and added to registry
     * @param ngo NGO address
     * @param metadataCid IPFS CID for NGO details (name, mission, logo, etc.)
     * @param kycHash Hash of KYC verification documents
     * @param attestor Address that performed KYC attestation
     * @param timestamp Block timestamp of approval
     */
    event NGOApproved(address indexed ngo, string metadataCid, bytes32 kycHash, address attestor, uint256 timestamp);

    /**
     * @notice Emitted when an NGO is removed from registry
     * @param ngo NGO address
     * @param metadataCid Last known metadata CID
     * @param timestamp Block timestamp of removal
     */
    event NGORemoved(address indexed ngo, string metadataCid, uint256 timestamp);

    /**
     * @notice Emitted when NGO metadata or KYC is updated
     * @param ngo NGO address
     * @param oldMetadataCid Previous metadata CID
     * @param newMetadataCid New metadata CID
     * @param newVersion Incremented version number
     */
    event NGOUpdated(address indexed ngo, string oldMetadataCid, string newMetadataCid, uint256 newVersion);

    /**
     * @notice Emitted when current NGO is proposed, executed, or emergency set
     * @param oldNGO Previous current NGO address
     * @param newNGO New current NGO address
     * @param eta Execution timestamp (0 if immediate, future timestamp if timelocked)
     */
    event CurrentNGOSet(address indexed oldNGO, address indexed newNGO, uint256 eta);

    /**
     * @notice Emitted when a donation is recorded for an NGO
     * @param ngo NGO address receiving donation
     * @param amount Donation amount
     * @param newTotalReceived Cumulative total received by this NGO
     */
    event DonationRecorded(address indexed ngo, uint256 amount, uint256 newTotalReceived);

    // ============================================
    // ERRORS
    // ============================================

    /// @notice Zero address provided where non-zero required
    error ZeroAddress();

    /// @notice Caller lacks required role
    error Unauthorized(bytes32 roleId, address account);

    /// @notice Invalid NGO address
    error InvalidNGOAddress();

    /// @notice NGO already approved
    error NGOAlreadyApproved();

    /// @notice NGO not found in approved list
    error NGONotApproved();

    /// @notice Invalid metadata CID (empty string)
    error InvalidMetadataCid();

    /// @notice Invalid attestor address
    error InvalidAttestor();

    /// @notice No pending timelock operation
    error NoTimelockPending();

    /// @notice Timelock delay has not elapsed yet
    error TimelockNotReady();

    // ============================================
    // MODIFIERS
    // ============================================

    /**
     * @notice Restricts access to accounts with specific role
     * @dev Reverts if caller does not have the required role
     * @param roleId The role to check
     */
    modifier onlyRole(bytes32 roleId) {
        if (!aclManager.hasRole(roleId, msg.sender)) {
            revert Unauthorized(roleId, msg.sender);
        }
        _;
    }

    // ============================================
    // INITIALIZATION
    // ============================================

    /**
     * @notice Initializes the NGO registry
     * @dev Only callable once due to initializer modifier.
     *      Sets up ACL manager reference.
     * @param acl Address of ACLManager contract
     */
    function initialize(address acl) external initializer {
        if (acl == address(0)) revert ZeroAddress();
        __Pausable_init();
        aclManager = IACLManager(acl);
    }

    // ============================================
    // EXTERNAL VIEW FUNCTIONS
    // ============================================

    /**
     * @notice Returns the current default NGO address
     * @dev This is the default recipient for donations when no specific NGO is chosen
     * @return Current NGO address (may be address(0) if none set)
     */
    function currentNGO() public view returns (address) {
        return _state().currentNGO;
    }

    /**
     * @notice Returns the pending NGO address waiting for timelock
     * @dev Returns address(0) if no change is pending
     * @return Pending NGO address
     */
    function pendingCurrentNGO() public view returns (address) {
        return _state().pendingCurrentNGO;
    }

    /**
     * @notice Returns the timestamp when pending NGO change can be executed
     * @dev Returns 0 if no change is pending
     * @return ETA timestamp (seconds since epoch)
     */
    function currentNGOChangeETA() public view returns (uint256) {
        return _state().currentNGOChangeETA;
    }

    /**
     * @notice Returns list of all approved NGO addresses
     * @dev Returns a copy of storage array to avoid external mutation.
     *      Order is insertion order (chronological).
     * @return Array of approved NGO addresses
     */
    function approvedNGOs() external view returns (address[] memory) {
        GiveTypes.NGORegistryState storage s = _state();
        address[] memory copy = new address[](s.approvedNGOs.length);
        for (uint256 i = 0; i < s.approvedNGOs.length; i++) {
            copy[i] = s.approvedNGOs[i];
        }
        return copy;
    }

    /**
     * @notice Checks if an NGO is approved
     * @dev Quick lookup without fetching full NGO info
     * @param ngo NGO address to check
     * @return True if approved, false otherwise
     */
    function isApproved(address ngo) public view returns (bool) {
        return _state().isApproved[ngo];
    }

    /**
     * @notice Returns detailed information about an NGO
     * @dev Returns all stored metadata and stats for an NGO
     * @param ngo NGO address
     * @return metadataCid IPFS CID for NGO details
     * @return kycHash Hash of KYC verification documents
     * @return attestor Address that performed KYC attestation
     * @return createdAt Timestamp when NGO was added
     * @return updatedAt Timestamp of last update
     * @return version Incremental version number (starts at 1)
     * @return totalReceived Cumulative donations received
     * @return isActive Whether NGO is currently active
     */
    function ngoInfo(address ngo)
        external
        view
        returns (
            string memory metadataCid,
            bytes32 kycHash,
            address attestor,
            uint256 createdAt,
            uint256 updatedAt,
            uint256 version,
            uint256 totalReceived,
            bool isActive
        )
    {
        GiveTypes.NGOInfo storage info = _state().ngoInfo[ngo];
        return (
            info.metadataCid,
            info.kycHash,
            info.attestor,
            info.createdAt,
            info.updatedAt,
            info.version,
            info.totalReceived,
            info.isActive
        );
    }

    // ============================================
    // EXTERNAL FUNCTIONS - NGO MANAGEMENT
    // ============================================

    /**
     * @notice Adds a new NGO to the registry
     * @dev Only callable by NGO_MANAGER when not paused.
     *      First NGO added automatically becomes current NGO.
     *      Requires KYC attestation for compliance.
     * @param ngo NGO address (must not be zero)
     * @param metadataCid IPFS CID for NGO details
     * @param kycHash Hash of KYC verification documents
     * @param attestor Address that performed KYC attestation
     */
    function addNGO(address ngo, string calldata metadataCid, bytes32 kycHash, address attestor)
        external
        onlyRole(NGO_MANAGER_ROLE)
        whenNotPaused
    {
        if (ngo == address(0)) revert InvalidNGOAddress();
        if (_state().isApproved[ngo]) revert NGOAlreadyApproved();
        if (bytes(metadataCid).length == 0) revert InvalidMetadataCid();
        if (attestor == address(0)) revert InvalidAttestor();

        GiveTypes.NGORegistryState storage s = _state();
        s.isApproved[ngo] = true;

        GiveTypes.NGOInfo storage info = s.ngoInfo[ngo];
        info.metadataCid = metadataCid;
        info.kycHash = kycHash;
        info.attestor = attestor;
        info.createdAt = block.timestamp;
        info.updatedAt = block.timestamp;
        info.version = 1;
        info.totalReceived = 0;
        info.isActive = true;

        s.approvedNGOs.push(ngo);

        // Auto-set first NGO as current NGO
        if (s.currentNGO == address(0)) {
            s.currentNGO = ngo;
            emit CurrentNGOSet(address(0), ngo, 0);
        }

        emit NGOApproved(ngo, metadataCid, kycHash, attestor, block.timestamp);
    }

    /**
     * @notice Removes an NGO from the registry
     * @dev Only callable by NGO_MANAGER.
     *      Marks NGO as inactive and removes from approved list.
     *      If removing current NGO, automatically sets to first approved NGO (or address(0)).
     * @param ngo NGO address to remove
     */
    function removeNGO(address ngo) external onlyRole(NGO_MANAGER_ROLE) {
        GiveTypes.NGORegistryState storage s = _state();
        if (!s.isApproved[ngo]) revert NGONotApproved();

        string memory metadataCid = s.ngoInfo[ngo].metadataCid;
        s.isApproved[ngo] = false;
        s.ngoInfo[ngo].isActive = false;
        s.ngoInfo[ngo].updatedAt = block.timestamp;

        _removeApprovedNGO(s, ngo);

        // If removing current NGO, auto-select first available NGO
        if (s.currentNGO == ngo) {
            s.currentNGO = s.approvedNGOs.length > 0 ? s.approvedNGOs[0] : address(0);
            emit CurrentNGOSet(ngo, s.currentNGO, 0);
        }

        emit NGORemoved(ngo, metadataCid, block.timestamp);
    }

    /**
     * @notice Updates an NGO's metadata and/or KYC hash
     * @dev Only callable by NGO_MANAGER.
     *      Increments version number for change tracking.
     *      KYC hash is optional (set to bytes32(0) to skip update).
     * @param ngo NGO address to update
     * @param newMetadataCid New IPFS CID for NGO details
     * @param newKycHash New KYC hash (or bytes32(0) to keep existing)
     */
    function updateNGO(address ngo, string calldata newMetadataCid, bytes32 newKycHash)
        external
        onlyRole(NGO_MANAGER_ROLE)
    {
        GiveTypes.NGORegistryState storage s = _state();
        if (!s.isApproved[ngo]) revert NGONotApproved();
        if (bytes(newMetadataCid).length == 0) revert InvalidMetadataCid();

        GiveTypes.NGOInfo storage info = s.ngoInfo[ngo];
        string memory oldMetadataCid = info.metadataCid;
        info.metadataCid = newMetadataCid;
        if (newKycHash != bytes32(0)) {
            info.kycHash = newKycHash;
        }
        info.updatedAt = block.timestamp;
        info.version++;

        emit NGOUpdated(ngo, oldMetadataCid, newMetadataCid, info.version);
    }

    /**
     * @notice Proposes a new current NGO (starts timelock)
     * @dev Only callable by NGO_MANAGER.
     *      Requires 24-hour delay before execution.
     *      Allows setting to address(0) to have no default NGO.
     * @param ngo New NGO address to propose (must be approved unless address(0))
     */
    function proposeCurrentNGO(address ngo) external onlyRole(NGO_MANAGER_ROLE) {
        GiveTypes.NGORegistryState storage s = _state();
        if (ngo != address(0) && !s.isApproved[ngo]) revert NGONotApproved();

        s.pendingCurrentNGO = ngo;
        s.currentNGOChangeETA = block.timestamp + TIMELOCK_DELAY;

        emit CurrentNGOSet(s.currentNGO, ngo, s.currentNGOChangeETA);
    }

    /**
     * @notice Executes a pending current NGO change
     * @dev Callable by anyone after timelock delay has elapsed.
     *      Permissionless execution ensures timelock cannot be blocked.
     */
    function executeCurrentNGOChange() external {
        GiveTypes.NGORegistryState storage s = _state();
        if (s.currentNGOChangeETA == 0) revert NoTimelockPending();
        if (block.timestamp < s.currentNGOChangeETA) revert TimelockNotReady();

        address oldNGO = s.currentNGO;
        s.currentNGO = s.pendingCurrentNGO;
        s.pendingCurrentNGO = address(0);
        s.currentNGOChangeETA = 0;

        emit CurrentNGOSet(oldNGO, s.currentNGO, 0);
    }

    /**
     * @notice Emergency override to immediately set current NGO
     * @dev Only callable by PROTOCOL_ADMIN role.
     *      Bypasses timelock for emergency situations.
     *      Clears any pending timelock operation.
     * @param ngo New NGO address (must be approved unless address(0))
     */
    function emergencySetCurrentNGO(address ngo) external onlyRole(aclManager.protocolAdminRole()) {
        GiveTypes.NGORegistryState storage s = _state();
        if (ngo != address(0) && !s.isApproved[ngo]) revert NGONotApproved();

        address oldNGO = s.currentNGO;
        s.currentNGO = ngo;
        s.pendingCurrentNGO = address(0);
        s.currentNGOChangeETA = 0;

        emit CurrentNGOSet(oldNGO, ngo, 0);
    }

    // ============================================
    // EXTERNAL FUNCTIONS - DONATION TRACKING
    // ============================================

    /**
     * @notice Records a donation to an NGO
     * @dev Only callable by DONATION_RECORDER (typically vault contracts).
     *      Updates cumulative total received for analytics.
     * @param ngo NGO address receiving donation
     * @param amount Donation amount (in asset units)
     */
    function recordDonation(address ngo, uint256 amount) external onlyRole(DONATION_RECORDER_ROLE) {
        GiveTypes.NGORegistryState storage s = _state();
        if (!s.isApproved[ngo]) revert NGONotApproved();

        GiveTypes.NGOInfo storage info = s.ngoInfo[ngo];
        info.totalReceived += amount;
        emit DonationRecorded(ngo, amount, info.totalReceived);
    }

    // ============================================
    // EXTERNAL FUNCTIONS - EMERGENCY CONTROLS
    // ============================================

    /**
     * @notice Pauses the registry (prevents NGO additions)
     * @dev Only callable by GUARDIAN.
     *      Pausing prevents new NGOs from being added but allows other operations.
     */
    function pause() external onlyRole(GUARDIAN_ROLE) {
        _pause();
    }

    /**
     * @notice Unpauses the registry
     * @dev Only callable by GUARDIAN
     */
    function unpause() external onlyRole(GUARDIAN_ROLE) {
        _unpause();
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
        if (!aclManager.hasRole(ROLE_UPGRADER, msg.sender)) {
            revert Unauthorized(ROLE_UPGRADER, msg.sender);
        }
    }

    // ============================================
    // PRIVATE FUNCTIONS
    // ============================================

    /**
     * @notice Returns storage reference for NGO registry state
     * @dev Uses Diamond Storage pattern via StorageLib
     * @return NGO registry state storage reference
     */
    function _state() private view returns (GiveTypes.NGORegistryState storage) {
        return StorageLib.ngoRegistry();
    }

    /**
     * @notice Removes an NGO from the approved list using swap-and-pop
     * @dev O(n) search, O(1) removal. Called by removeNGO().
     * @param s Storage reference for NGO registry state
     * @param ngo NGO address to remove
     */
    function _removeApprovedNGO(GiveTypes.NGORegistryState storage s, address ngo) private {
        address[] storage list = s.approvedNGOs;
        for (uint256 i = 0; i < list.length; i++) {
            if (list[i] == ngo) {
                list[i] = list[list.length - 1];
                list.pop();
                break;
            }
        }
    }
}
