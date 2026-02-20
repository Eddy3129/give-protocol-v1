// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import "../storage/StorageLib.sol";
import "../types/GiveTypes.sol";
import "../utils/GiveErrors.sol";
import "../interfaces/IACLManager.sol";
import "../registry/CampaignRegistry.sol";

/// @title PayoutRouter
/// @notice Campaign-aware router that distributes harvested yield between campaigns, supporters, and protocol.
contract PayoutRouter is
    Initializable,
    UUPSUpgradeable,
    AccessControlUpgradeable,
    ReentrancyGuardUpgradeable,
    PausableUpgradeable
{
    using SafeERC20 for IERC20;

    bytes32 public constant VAULT_MANAGER_ROLE = keccak256("VAULT_MANAGER_ROLE");
    bytes32 public constant FEE_MANAGER_ROLE = keccak256("FEE_MANAGER_ROLE");
    bytes32 public constant ROLE_UPGRADER = keccak256("ROLE_UPGRADER");

    uint256 public constant MAX_FEE_BPS = 1_000; // 10%
    uint256 private constant PRECISION = 1e18;

    /// @notice Minimum delay before fee change takes effect (7 days)
    uint256 public constant FEE_CHANGE_DELAY = 7 days;

    /// @notice Maximum fee increase per change (250 = 2.5%)
    uint256 public constant MAX_FEE_INCREASE_PER_CHANGE = 250;

    event YieldPreferenceUpdated(
        address indexed user,
        address indexed vault,
        bytes32 indexed campaignId,
        address beneficiary,
        uint8 allocationPercentage
    );
    event UserSharesUpdated(address indexed user, address indexed vault, uint256 shares, uint256 totalShares);
    event CampaignVaultRegistered(address indexed vault, bytes32 indexed campaignId);
    event CampaignPayoutExecuted(
        bytes32 indexed campaignId,
        address indexed vault,
        address recipient,
        uint256 campaignAmount,
        uint256 protocolAmount
    );
    event BeneficiaryPaid(address indexed user, address indexed vault, address beneficiary, uint256 amount);
    event YieldRecorded(address indexed vault, address indexed asset, uint256 totalYield, uint256 deltaPerShare);
    event YieldClaimed(
        address indexed user,
        address indexed vault,
        address indexed asset,
        uint256 campaignAmount,
        uint256 beneficiaryAmount,
        uint256 protocolAmount
    );
    event StalePrefCleared(address indexed user, address indexed vault);
    event VaultReassigned(address indexed vault, bytes32 indexed oldCampaignId, bytes32 indexed newCampaignId);
    event FeeConfigUpdated(
        address indexed oldRecipient, address indexed newRecipient, uint256 oldFeeBps, uint256 newFeeBps
    );
    event ProtocolTreasuryUpdated(address indexed oldTreasury, address indexed newTreasury);
    event AuthorizedCallerUpdated(address indexed caller, bool authorized);
    event EmergencyWithdrawal(address indexed asset, address indexed recipient, uint256 amount);
    event FeeChangeProposed(
        uint256 indexed nonce, address indexed recipient, uint256 feeBps, uint256 effectiveTimestamp
    );
    event FeeChangeExecuted(uint256 indexed nonce, uint256 newFeeBps, address newRecipient);
    event FeeChangeCancelled(uint256 indexed nonce);

    error Unauthorized(bytes32 roleId, address account);
    error VaultNotRegistered(address vault);
    error InvalidAllocation(uint8 allocation);
    error InvalidBeneficiary();
    error CampaignMismatch(bytes32 expected, bytes32 provided);

    struct AllocationResult {
        uint256 campaignAmount;
        uint256 beneficiaryAmount;
        uint256 protocolAmount;
        address payoutTo;
    }

    /// @dev Groups claimYield inputs to avoid stack-too-deep in _calculateAllocations
    struct CalcParams {
        bytes32 campaignId;
        address defaultBeneficiary;
        address user;
        address vault;
        uint256 userYield;
    }

    // ============================================
    // STATE VARIABLES
    // ============================================

    /// @notice ACL manager for protocol-wide role delegation
    IACLManager public aclManager;

    event ACLManagerUpdated(address indexed previousManager, address indexed newManager);

    // ============================================
    // INITIALIZATION
    // ============================================

    function initialize(
        address admin_,
        address acl_,
        address campaignRegistry_,
        address feeRecipient_,
        address protocolTreasury_,
        uint256 feeBps_
    ) external initializer {
        if (
            admin_ == address(0) || acl_ == address(0) || campaignRegistry_ == address(0) || feeRecipient_ == address(0)
                || protocolTreasury_ == address(0)
        ) {
            revert GiveErrors.ZeroAddress();
        }
        if (feeBps_ > MAX_FEE_BPS) revert GiveErrors.InvalidConfiguration();

        __AccessControl_init();
        __ReentrancyGuard_init();
        __Pausable_init();
        __UUPSUpgradeable_init();

        // Grant DEFAULT_ADMIN_ROLE to deployer for local AccessControl management
        _grantRole(DEFAULT_ADMIN_ROLE, admin_);

        _setACLManager(acl_);

        GiveTypes.PayoutRouterState storage s = _state();
        s.campaignRegistry = campaignRegistry_;
        s.feeRecipient = feeRecipient_;
        s.protocolTreasury = protocolTreasury_;
        s.feeBps = feeBps_;
        s.validAllocations[0] = 50;
        s.validAllocations[1] = 75;
        s.validAllocations[2] = 100;
    }

    // ===== View helpers =====

    function campaignRegistry() public view returns (address) {
        return _state().campaignRegistry;
    }

    function feeRecipient() public view returns (address) {
        return _state().feeRecipient;
    }

    function protocolTreasury() public view returns (address) {
        return _state().protocolTreasury;
    }

    function feeBps() public view returns (uint256) {
        return _state().feeBps;
    }

    function totalDistributions() external view returns (uint256) {
        return _state().totalDistributions;
    }

    function authorizedCallers(address caller) external view returns (bool) {
        return _state().authorizedCallers[caller];
    }

    function getValidAllocations() external view returns (uint8[3] memory) {
        return _state().validAllocations;
    }

    function getVaultCampaign(address vault) external view returns (bytes32) {
        return _state().vaultCampaigns[vault];
    }

    function getVaultPreference(address user, address vault)
        external
        view
        returns (GiveTypes.CampaignPreference memory)
    {
        return _state().userPreferences[user][vault];
    }

    function getUserVaultShares(address user, address vault) external view returns (uint256) {
        return _state().userVaultShares[user][vault];
    }

    function getTotalVaultShares(address vault) external view returns (uint256) {
        return _state().totalVaultShares[vault];
    }

    /// @notice Returns all shareholders for a vault (unbounded — off-chain use only)
    /// @dev WARNING: This array is unbounded. Do NOT call on-chain with large depositor sets.
    ///      Use getVaultShareholdersPaged for on-chain or gas-sensitive contexts.
    function getVaultShareholders(address vault) external view returns (address[] memory) {
        GiveTypes.PayoutRouterState storage s = _state();
        address[] storage list = s.vaultShareholders[vault];
        address[] memory copy = new address[](list.length);
        for (uint256 i = 0; i < list.length; i++) {
            copy[i] = list[i];
        }
        return copy;
    }

    /// @notice Returns a paginated slice of shareholders for a vault
    /// @param vault The vault address to query
    /// @param offset Start index (0-based)
    /// @param limit Maximum number of results to return
    /// @return page Slice of shareholder addresses
    /// @return total Total number of shareholders
    function getVaultShareholdersPaged(address vault, uint256 offset, uint256 limit)
        external
        view
        returns (address[] memory page, uint256 total)
    {
        GiveTypes.PayoutRouterState storage s = _state();
        address[] storage list = s.vaultShareholders[vault];
        total = list.length;
        if (offset >= total || limit == 0) {
            return (new address[](0), total);
        }
        uint256 end = offset + limit;
        if (end > total) end = total;
        uint256 count = end - offset;
        page = new address[](count);
        for (uint256 i = 0; i < count; i++) {
            page[i] = list[offset + i];
        }
    }

    function getCampaignTotals(bytes32 campaignId) external view returns (uint256 payouts, uint256 protocolFees) {
        GiveTypes.PayoutRouterState storage s = _state();
        return (s.campaignTotalPayouts[campaignId], s.campaignProtocolFees[campaignId]);
    }

    function getPendingYield(address user, address vault, address asset) external view returns (uint256) {
        GiveTypes.PayoutRouterState storage s = _state();

        uint256 pending = s.pendingYield[vault][asset][user];
        uint256 shares = s.userVaultShares[user][vault];
        uint256 debt = s.userYieldDebt[vault][asset][user];
        uint256 acc = s.accumulatedYieldPerShare[vault][asset];

        if (shares == 0 || acc <= debt) {
            return pending;
        }

        uint256 newlyAccrued = (shares * (acc - debt)) / PRECISION;
        return pending + newlyAccrued;
    }

    // ===== Role-managed configuration =====

    function setAuthorizedCaller(address caller, bool authorized) external onlyRole(VAULT_MANAGER_ROLE) {
        if (caller == address(0)) revert GiveErrors.ZeroAddress();
        _state().authorizedCallers[caller] = authorized;
        emit AuthorizedCallerUpdated(caller, authorized);
    }

    /// @notice Propose a fee configuration change (subject to timelock)
    /// @dev Fee decreases are instant, increases have 7-day delay
    /// @param newRecipient New fee recipient address
    /// @param newFeeBps New fee in basis points
    function proposeFeeChange(address newRecipient, uint256 newFeeBps) external onlyRole(FEE_MANAGER_ROLE) {
        if (newRecipient == address(0)) revert GiveErrors.ZeroAddress();
        if (newFeeBps > MAX_FEE_BPS) revert GiveErrors.InvalidConfiguration();

        GiveTypes.PayoutRouterState storage s = _state();
        uint256 currentFee = s.feeBps;

        // Fee decreases are instant (user-friendly)
        if (newFeeBps <= currentFee) {
            address oldRecipient = s.feeRecipient;
            s.feeRecipient = newRecipient;
            s.feeBps = newFeeBps;
            emit FeeConfigUpdated(oldRecipient, newRecipient, currentFee, newFeeBps);
            return;
        }

        // Fee increases require timelock
        uint256 feeIncrease = newFeeBps - currentFee;
        if (feeIncrease > MAX_FEE_INCREASE_PER_CHANGE) {
            revert GiveErrors.FeeIncreaseTooLarge(feeIncrease, MAX_FEE_INCREASE_PER_CHANGE);
        }

        // Create pending fee change
        uint256 nonce = s.feeChangeNonce++;
        uint256 effectiveAt = block.timestamp + FEE_CHANGE_DELAY;

        GiveTypes.PendingFeeChange storage change = s.pendingFeeChanges[nonce];
        change.newFeeBps = newFeeBps;
        change.newRecipient = newRecipient;
        change.effectiveTimestamp = effectiveAt;
        change.exists = true;

        emit FeeChangeProposed(nonce, newRecipient, newFeeBps, effectiveAt);
    }

    /// @notice Execute a pending fee change after timelock expires
    /// @dev Can be called by anyone after delay passes
    /// @param nonce The fee change nonce to execute
    function executeFeeChange(uint256 nonce) external {
        GiveTypes.PayoutRouterState storage s = _state();
        GiveTypes.PendingFeeChange storage change = s.pendingFeeChanges[nonce];

        if (!change.exists) {
            revert GiveErrors.FeeChangeNotFound(nonce);
        }

        if (block.timestamp < change.effectiveTimestamp) {
            revert GiveErrors.TimelockNotExpired(block.timestamp, change.effectiveTimestamp);
        }

        address oldRecipient = s.feeRecipient;
        uint256 oldFee = s.feeBps;

        // Save new values before deleting pending change
        uint256 newFeeBps = change.newFeeBps;
        address newRecipient = change.newRecipient;

        // Apply fee change
        s.feeRecipient = newRecipient;
        s.feeBps = newFeeBps;

        // Clean up
        delete s.pendingFeeChanges[nonce];

        emit FeeConfigUpdated(oldRecipient, newRecipient, oldFee, newFeeBps);
        emit FeeChangeExecuted(nonce, newFeeBps, newRecipient);
    }

    /// @notice Cancel a pending fee change
    /// @dev Only FEE_MANAGER can cancel
    /// @param nonce The fee change nonce to cancel
    function cancelFeeChange(uint256 nonce) external onlyRole(FEE_MANAGER_ROLE) {
        GiveTypes.PayoutRouterState storage s = _state();
        GiveTypes.PendingFeeChange storage change = s.pendingFeeChanges[nonce];

        if (!change.exists) {
            revert GiveErrors.FeeChangeNotFound(nonce);
        }

        delete s.pendingFeeChanges[nonce];
        emit FeeChangeCancelled(nonce);
    }

    /// @notice Get details of a pending fee change
    /// @param nonce The fee change nonce
    /// @return newFeeBps Proposed new fee
    /// @return newRecipient Proposed new recipient
    /// @return effectiveTimestamp When change can be executed
    /// @return exists Whether the change exists
    function getPendingFeeChange(uint256 nonce)
        external
        view
        returns (uint256 newFeeBps, address newRecipient, uint256 effectiveTimestamp, bool exists)
    {
        GiveTypes.PendingFeeChange storage change = _state().pendingFeeChanges[nonce];
        return (change.newFeeBps, change.newRecipient, change.effectiveTimestamp, change.exists);
    }

    /// @notice Check if a fee change is ready to execute
    /// @param nonce The fee change nonce
    /// @return ready True if timelock has expired
    function isFeeChangeReady(uint256 nonce) external view returns (bool ready) {
        GiveTypes.PendingFeeChange storage change = _state().pendingFeeChanges[nonce];
        return change.exists && block.timestamp >= change.effectiveTimestamp;
    }

    function setProtocolTreasury(address newTreasury) external onlyRole(FEE_MANAGER_ROLE) {
        if (newTreasury == address(0)) revert GiveErrors.ZeroAddress();
        GiveTypes.PayoutRouterState storage s = _state();
        address oldTreasury = s.protocolTreasury;
        s.protocolTreasury = newTreasury;
        emit ProtocolTreasuryUpdated(oldTreasury, newTreasury);
    }

    function pause() external onlyRole(DEFAULT_ADMIN_ROLE) {
        _pause();
    }

    function unpause() external onlyRole(DEFAULT_ADMIN_ROLE) {
        _unpause();
    }

    // ===== Campaign wiring =====

    function registerCampaignVault(address vault, bytes32 campaignId) external onlyRole(VAULT_MANAGER_ROLE) {
        if (vault == address(0) || campaignId == bytes32(0)) {
            revert GiveErrors.ZeroAddress();
        }
        GiveTypes.PayoutRouterState storage s = _state();
        bytes32 oldCampaignId = s.vaultCampaigns[vault];
        s.vaultCampaigns[vault] = campaignId;

        if (oldCampaignId != bytes32(0) && oldCampaignId != campaignId) {
            emit VaultReassigned(vault, oldCampaignId, campaignId);
        }

        emit CampaignVaultRegistered(vault, campaignId);
    }

    // ===== Preferences =====

    function setVaultPreference(address vault, address beneficiary, uint8 allocationPercentage) external whenNotPaused {
        GiveTypes.PayoutRouterState storage s = _state();
        bytes32 campaignId = _requireCampaignForVault(s, vault);

        if (!_isValidAllocation(s, allocationPercentage)) {
            revert InvalidAllocation(allocationPercentage);
        }
        if (allocationPercentage < 100 && beneficiary == address(0)) {
            revert InvalidBeneficiary();
        }

        GiveTypes.CampaignPreference storage pref = s.userPreferences[msg.sender][vault];
        pref.campaignId = campaignId;
        pref.beneficiary = beneficiary;
        pref.allocationPercentage = allocationPercentage;
        pref.lastUpdated = block.timestamp;

        emit YieldPreferenceUpdated(msg.sender, vault, campaignId, beneficiary, allocationPercentage);
    }

    // ===== Share tracking =====

    function updateUserShares(address user, uint256 newShares) external onlyAuthorized {
        GiveTypes.PayoutRouterState storage s = _state();
        address vault = msg.sender;

        _syncUserPendingAcrossAssets(s, vault, user);

        uint256 oldShares = s.userVaultShares[user][vault];
        s.userVaultShares[user][vault] = newShares;
        s.totalVaultShares[vault] = s.totalVaultShares[vault] - oldShares + newShares;

        emit UserSharesUpdated(user, vault, newShares, s.totalVaultShares[vault]);
    }

    // ===== Yield distribution =====

    function recordYield(address asset, uint256 totalYield) external whenNotPaused onlyAuthorized returns (uint256) {
        if (asset == address(0)) revert GiveErrors.ZeroAddress();
        if (totalYield == 0) revert GiveErrors.InvalidAmount();

        GiveTypes.PayoutRouterState storage s = _state();
        address vault = msg.sender;

        bytes32 campaignId = _requireCampaignForVault(s, vault);
        GiveTypes.CampaignConfig memory campaign = CampaignRegistry(s.campaignRegistry).getCampaign(campaignId);
        if (campaign.payoutsHalted) revert GiveErrors.OperationNotAllowed();

        uint256 totalShares = s.totalVaultShares[vault];
        if (totalShares == 0) revert GiveErrors.InvalidConfiguration();

        IERC20 token = IERC20(asset);
        if (token.balanceOf(address(this)) < totalYield) {
            revert GiveErrors.InsufficientBalance();
        }

        uint256 deltaPerShare = (totalYield * PRECISION) / totalShares;
        if (deltaPerShare == 0) revert GiveErrors.InvalidAmount();

        s.accumulatedYieldPerShare[vault][asset] += deltaPerShare;
        _registerVaultAsset(s, vault, asset);
        s.totalDistributions += 1;

        emit YieldRecorded(vault, asset, totalYield, deltaPerShare);

        return totalYield;
    }

    function claimYield(address vault, address asset) external nonReentrant whenNotPaused returns (uint256) {
        if (asset == address(0)) revert GiveErrors.ZeroAddress();

        GiveTypes.PayoutRouterState storage s = _state();
        bytes32 campaignId = _requireCampaignForVault(s, vault);
        GiveTypes.CampaignConfig memory campaign = CampaignRegistry(s.campaignRegistry).getCampaign(campaignId);
        if (campaign.payoutsHalted) revert GiveErrors.OperationNotAllowed();

        address user = msg.sender;
        _accruePending(s, vault, asset, user);

        uint256 userYield = s.pendingYield[vault][asset][user];
        if (userYield == 0) {
            return 0;
        }

        s.pendingYield[vault][asset][user] = 0;

        GiveTypes.CampaignPreference storage pref = s.userPreferences[user][vault];
        if (pref.campaignId != bytes32(0) && pref.campaignId != campaignId) {
            delete s.userPreferences[user][vault];
            emit StalePrefCleared(user, vault);
        }

        AllocationResult memory allocation = _calculateAllocations(
            s,
            CalcParams({
                campaignId: campaignId,
                defaultBeneficiary: campaign.payoutRecipient,
                user: user,
                vault: vault,
                userYield: userYield
            })
        );

        _executeAllocationPayouts(s, asset, campaignId, campaign.payoutRecipient, user, vault, allocation);
        emit YieldClaimed(
            user, vault, asset, allocation.campaignAmount, allocation.beneficiaryAmount, allocation.protocolAmount
        );

        return allocation.campaignAmount + allocation.beneficiaryAmount + allocation.protocolAmount;
    }

    function emergencyWithdraw(address asset, address recipient, uint256 amount) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (asset == address(0) || recipient == address(0)) {
            revert GiveErrors.ZeroAddress();
        }
        IERC20(asset).safeTransfer(recipient, amount);
        emit EmergencyWithdrawal(asset, recipient, amount);
    }

    // ===== Internal helpers =====

    function _calculateAllocations(GiveTypes.PayoutRouterState storage s, CalcParams memory p)
        private
        view
        returns (AllocationResult memory allocation)
    {
        allocation.protocolAmount = (p.userYield * s.feeBps) / 10_000;
        uint256 netYield = p.userYield - allocation.protocolAmount;

        GiveTypes.CampaignPreference memory pref = s.userPreferences[p.user][p.vault];
        if (pref.campaignId != bytes32(0) && pref.campaignId != p.campaignId) {
            revert CampaignMismatch(p.campaignId, pref.campaignId);
        }

        uint8 allocationPercentage = pref.allocationPercentage == 0 ? 100 : pref.allocationPercentage;
        allocation.payoutTo = pref.beneficiary == address(0) ? p.defaultBeneficiary : pref.beneficiary;

        allocation.campaignAmount = (netYield * allocationPercentage) / 100;
        allocation.beneficiaryAmount = netYield - allocation.campaignAmount;

        if (allocation.beneficiaryAmount > 0 && allocation.payoutTo == address(0)) {
            allocation.payoutTo = s.feeRecipient;
        }
    }

    function _executeAllocationPayouts(
        GiveTypes.PayoutRouterState storage s,
        address asset,
        bytes32 campaignId,
        address campaignRecipient,
        address user,
        address vault,
        AllocationResult memory allocation
    ) private {
        IERC20 token = IERC20(asset);

        if (allocation.protocolAmount > 0) {
            token.safeTransfer(s.protocolTreasury, allocation.protocolAmount);
            s.campaignProtocolFees[campaignId] += allocation.protocolAmount;
        }

        if (allocation.campaignAmount > 0) {
            token.safeTransfer(campaignRecipient, allocation.campaignAmount);
            s.campaignTotalPayouts[campaignId] += allocation.campaignAmount;
        }

        if (allocation.beneficiaryAmount > 0) {
            token.safeTransfer(allocation.payoutTo, allocation.beneficiaryAmount);
            emit BeneficiaryPaid(user, vault, allocation.payoutTo, allocation.beneficiaryAmount);
        }

        emit CampaignPayoutExecuted(
            campaignId, vault, campaignRecipient, allocation.campaignAmount, allocation.protocolAmount
        );
    }

    function _syncUserPendingAcrossAssets(GiveTypes.PayoutRouterState storage s, address vault, address user) private {
        address[] storage assets = s.vaultAssets[vault];
        for (uint256 i = 0; i < assets.length; i++) {
            _accruePending(s, vault, assets[i], user);
        }
    }

    function _accruePending(GiveTypes.PayoutRouterState storage s, address vault, address asset, address user) private {
        uint256 shares = s.userVaultShares[user][vault];
        uint256 acc = s.accumulatedYieldPerShare[vault][asset];
        uint256 debt = s.userYieldDebt[vault][asset][user];

        if (shares > 0 && acc > debt) {
            uint256 accrued = (shares * (acc - debt)) / PRECISION;
            if (accrued > 0) {
                s.pendingYield[vault][asset][user] += accrued;
            }
        }

        s.userYieldDebt[vault][asset][user] = acc;
    }

    function _registerVaultAsset(GiveTypes.PayoutRouterState storage s, address vault, address asset) private {
        if (s.hasVaultAsset[vault][asset]) {
            return;
        }
        s.hasVaultAsset[vault][asset] = true;
        s.vaultAssets[vault].push(asset);
    }

    function _requireCampaignForVault(GiveTypes.PayoutRouterState storage s, address vault)
        private
        view
        returns (bytes32)
    {
        bytes32 campaignId = s.vaultCampaigns[vault];
        if (campaignId == bytes32(0)) revert VaultNotRegistered(vault);
        return campaignId;
    }

    function _isValidAllocation(GiveTypes.PayoutRouterState storage s, uint8 allocation) private view returns (bool) {
        for (uint256 i = 0; i < s.validAllocations.length; i++) {
            if (s.validAllocations[i] == allocation) return true;
        }
        return false;
    }

    function _state() private view returns (GiveTypes.PayoutRouterState storage) {
        return StorageLib.payoutRouter();
    }

    modifier onlyAuthorized() {
        if (!_state().authorizedCallers[msg.sender]) {
            revert GiveErrors.UnauthorizedCaller(msg.sender);
        }
        _;
    }

    /// @inheritdoc UUPSUpgradeable
    function _authorizeUpgrade(address) internal view override {
        if (!aclManager.hasRole(ROLE_UPGRADER, msg.sender)) {
            revert Unauthorized(ROLE_UPGRADER, msg.sender);
        }
    }

    /// @notice Sets ACL manager address
    /// @param acl New ACL manager address
    function _setACLManager(address acl) internal {
        if (acl == address(0)) revert GiveErrors.ZeroAddress();
        address previous = address(aclManager);
        aclManager = IACLManager(acl);
        emit ACLManagerUpdated(previous, acl);
    }

    /// @notice Override role check to delegate to ACL manager
    /// @dev Implements dual-source role checking:
    ///      1. First checks external ACL manager (if set and account has role)
    ///      2. Falls back to local AccessControl storage
    /// @param role The role identifier to check
    /// @param account The address to verify
    function _checkRole(bytes32 role, address account) internal view override {
        // Try ACL manager first if available
        if (address(aclManager) != address(0) && aclManager.hasRole(role, account)) {
            return;
        }
        // Fall back to local role storage
        super._checkRole(role, account);
    }
}
