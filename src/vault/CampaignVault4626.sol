// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import "./GiveVault4626.sol";
import "../storage/StorageLib.sol";
import "../types/GiveTypes.sol";

interface ICampaignVaultFactoryRouter {
    function payoutRouter() external view returns (address);
}

/**
 * @title CampaignVault4626
 * @author GIVE Labs
 * @notice Campaign-aware UUPS-upgradeable vault with campaign metadata binding
 * @dev Extends GiveVault4626 with campaign-specific metadata storage.
 *      Inherits UUPS upgradeability from GiveVault4626.
 *
 *      Key Features:
 *      - Campaign ID association
 *      - Strategy ID tracking
 *      - Lock profile configuration (flexible/locked/progressive)
 *      - Factory address tracking
 *
 *      Architecture Changes from v0.5:
 *      - ❌ REMOVED: Constructor-based initialization
 *      - ✅ ADDED: initialize() replaces constructor
 *      - ✅ ADDED: Two-step initialization pattern (initialize → initializeCampaign)
 *      - Inherits UUPS upgradeability from GiveVault4626
 *
 *      Initialization Flow:
 *      1. Factory deploys UUPS proxy pointing to CampaignVault4626 implementation
 *      2. Factory calls initialize(asset, name, symbol, admin, acl, implementation)
 *      3. Factory calls initializeCampaign(campaignId, strategyId, lockProfile)
 *
 *      Security Model:
 *      - Inherits all roles from GiveVault4626
 *      - Campaign metadata can only be set once by factory
 */
contract CampaignVault4626 is GiveVault4626 {
    // ============================================
    // STATE VARIABLES
    // ============================================

    /// @notice Factory address that deployed this vault
    address private _factory;

    /// @notice Tracks whether campaign metadata has been initialized
    bool private _campaignInitialized;

    // ============================================
    // EVENTS
    // ============================================

    event CampaignMetadataInitialized(
        bytes32 indexed campaignId, bytes32 indexed strategyId, bytes32 lockProfile, address indexed factory
    );

    // ============================================
    // ERRORS
    // ============================================

    error CampaignAlreadyInitialized();
    error UnauthorizedInitializer(address caller);
    error NotFactory(address caller, address expectedFactory);

    // ============================================
    // INITIALIZATION
    // ============================================

    /**
     * @notice Initializes the campaign vault with factory tracking
     * @dev Extends parent initialize() to store factory address for access control.
     *      Initialization flow:
     *      1. Factory calls initialize(asset, name, symbol, admin, acl, implementation, factory)
     *      2. Factory calls initializeCampaign(campaignId, strategyId, lockProfile)
     * @param asset_ Underlying ERC20 asset (e.g., USDC, WETH)
     * @param name_ ERC20 token name for vault shares
     * @param symbol_ ERC20 token symbol for vault shares
     * @param admin_ Admin address to receive DEFAULT_ADMIN_ROLE
     * @param acl_ ACL manager address for role checks
     * @param implementation_ Address of the vault implementation contract
     * @param factory_ Factory address authorized to call initializeCampaign()
     */
    function initialize(
        address asset_,
        string memory name_,
        string memory symbol_,
        address admin_,
        address acl_,
        address implementation_,
        address factory_
    ) public initializer {
        if (factory_ == address(0)) revert ZeroAddress();

        // Call parent initializer to set up base vault
        super.initialize(asset_, name_, symbol_, admin_, acl_, implementation_);

        // Store factory for access control
        _factory = factory_;
        _campaignInitialized = false;
    }

    /**
     * @notice One-time initializer invoked by the factory to bind campaign metadata
     * @dev Can only be called once by the factory that deployed this vault.
     *      Stores campaign-specific metadata in separate storage slot.
     * @param campaignId The campaign this vault is associated with
     * @param strategyId The yield strategy this vault uses
     * @param lockProfile The lock profile (flexible/locked/progressive)
     */
    function initializeCampaign(bytes32 campaignId, bytes32 strategyId, bytes32 lockProfile) external {
        if (_campaignInitialized) revert CampaignAlreadyInitialized();
        if (msg.sender != _factory) revert NotFactory(msg.sender, _factory);

        address router = ICampaignVaultFactoryRouter(_factory).payoutRouter();
        if (router == address(0)) revert ZeroAddress();

        GiveTypes.VaultConfig storage cfg = _vaultConfig();
        address oldRouter = cfg.donationRouter;
        cfg.donationRouter = router;
        emit PayoutRouterUpdated(oldRouter, router);

        // Store campaign metadata in StorageLib
        bytes32 id = vaultId();
        GiveTypes.CampaignVaultMeta storage meta = StorageLib.campaignVaultMeta(id);
        meta.id = id;
        meta.campaignId = campaignId;
        meta.strategyId = strategyId;
        meta.lockProfile = lockProfile;
        meta.factory = _factory;
        meta.exists = true;

        _campaignInitialized = true;

        emit CampaignMetadataInitialized(campaignId, strategyId, lockProfile, msg.sender);
    }

    // ============================================
    // VIEW FUNCTIONS
    // ============================================

    /**
     * @notice Returns the campaign metadata bound to this vault
     * @dev Reverts if campaign metadata not initialized
     * @return campaignId Campaign identifier
     * @return strategyId Strategy identifier
     * @return lockProfile Lock profile identifier
     * @return factoryAddr Factory address that created this vault
     */
    function getCampaignMetadata()
        external
        view
        returns (bytes32 campaignId, bytes32 strategyId, bytes32 lockProfile, address factoryAddr)
    {
        GiveTypes.CampaignVaultMeta storage meta = StorageLib.ensureCampaignVault(vaultId());
        return (meta.campaignId, meta.strategyId, meta.lockProfile, meta.factory);
    }

    /**
     * @notice Returns whether campaign metadata has been initialized
     * @return True if initializeCampaign() has been called
     */
    function campaignInitialized() external view returns (bool) {
        return _campaignInitialized;
    }

    /**
     * @notice Returns the factory address that deployed this vault
     * @return Factory address authorized to initialize campaign metadata
     */
    function factory() external view returns (address) {
        return _factory;
    }
}
