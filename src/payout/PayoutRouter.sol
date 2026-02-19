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
    uint256 public constant PROTOCOL_FEE_BPS = 250; // 2.5%

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

    struct YieldTotals {
        uint256 campaign;
        uint256 beneficiary;
        uint256 protocol;
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

    function getVaultShareholders(address vault) external view returns (address[] memory) {
        GiveTypes.PayoutRouterState storage s = _state();
        address[] storage list = s.vaultShareholders[vault];
        address[] memory copy = new address[](list.length);
        for (uint256 i = 0; i < list.length; i++) {
            copy[i] = list[i];
        }
        return copy;
    }

    function getCampaignTotals(bytes32 campaignId) external view returns (uint256 payouts, uint256 protocolFees) {
        GiveTypes.PayoutRouterState storage s = _state();
        return (s.campaignTotalPayouts[campaignId], s.campaignProtocolFees[campaignId]);
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
        s.vaultCampaigns[vault] = campaignId;
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

    function updateUserShares(address user, address vault, uint256 newShares) external onlyAuthorized {
        GiveTypes.PayoutRouterState storage s = _state();
        uint256 oldShares = s.userVaultShares[user][vault];
        s.userVaultShares[user][vault] = newShares;
        s.totalVaultShares[vault] = s.totalVaultShares[vault] - oldShares + newShares;

        if (oldShares == 0 && newShares > 0) {
            if (!s.hasVaultShare[vault][user]) {
                s.vaultShareholders[vault].push(user);
                s.hasVaultShare[vault][user] = true;
            }
        } else if (oldShares > 0 && newShares == 0) {
            if (s.hasVaultShare[vault][user]) {
                _removeShareholder(s, vault, user);
                s.hasVaultShare[vault][user] = false;
            }
        }

        emit UserSharesUpdated(user, vault, newShares, s.totalVaultShares[vault]);
    }

    // ===== Yield distribution =====

    function distributeToAllUsers(address asset, uint256 totalYield)
        external
        nonReentrant
        whenNotPaused
        onlyAuthorized
        returns (uint256)
    {
        if (asset == address(0)) revert GiveErrors.ZeroAddress();
        if (totalYield == 0) revert GiveErrors.InvalidAmount();

        IERC20 token = IERC20(asset);
        if (token.balanceOf(address(this)) < totalYield) {
            revert GiveErrors.InsufficientBalance();
        }

        GiveTypes.PayoutRouterState storage s = _state();
        bytes32 campaignId = _requireCampaignForVault(s, msg.sender);
        GiveTypes.CampaignConfig memory campaign = CampaignRegistry(s.campaignRegistry).getCampaign(campaignId);
        if (campaign.payoutsHalted) revert GiveErrors.OperationNotAllowed();

        uint256 totalShares = s.totalVaultShares[msg.sender];
        if (totalShares == 0) revert GiveErrors.InvalidConfiguration();

        YieldTotals memory totals =
            _distributeLoop(s, token, campaignId, campaign.payoutRecipient, msg.sender, totalYield, totalShares);

        if (totals.protocol > 0) {
            token.safeTransfer(s.protocolTreasury, totals.protocol);
            s.campaignProtocolFees[campaignId] += totals.protocol;
        }

        if (totals.campaign > 0) {
            token.safeTransfer(campaign.payoutRecipient, totals.campaign);
            s.campaignTotalPayouts[campaignId] += totals.campaign;
        }

        s.totalDistributions += 1;

        emit CampaignPayoutExecuted(campaignId, msg.sender, campaign.payoutRecipient, totals.campaign, totals.protocol);

        return totals.campaign + totals.beneficiary + totals.protocol;
    }

    function emergencyWithdraw(address asset, address recipient, uint256 amount) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (asset == address(0) || recipient == address(0)) {
            revert GiveErrors.ZeroAddress();
        }
        IERC20(asset).safeTransfer(recipient, amount);
        emit EmergencyWithdrawal(asset, recipient, amount);
    }

    // ===== Internal helpers =====

    function _calculateAllocations(
        GiveTypes.PayoutRouterState storage s,
        bytes32 campaignId,
        address defaultBeneficiary,
        address user,
        address vault,
        uint256 userYield
    )
        private
        view
        returns (uint256 campaignAmount, uint256 beneficiaryAmount, uint256 protocolAmount, address payoutTo)
    {
        protocolAmount =
            (userYield * s.feeBps) / 10_000;
        uint256 netYield = userYield - protocolAmount;

        GiveTypes.CampaignPreference memory pref = s.userPreferences[user][vault];
        if (pref.campaignId != bytes32(0) && pref.campaignId != campaignId) {
            revert CampaignMismatch(campaignId, pref.campaignId);
        }

        uint8 allocation = pref.allocationPercentage == 0 ? 100 : pref.allocationPercentage;
        payoutTo = pref.beneficiary == address(0) ? defaultBeneficiary : pref.beneficiary;

        campaignAmount = (netYield * allocation) / 100;
        beneficiaryAmount = netYield - campaignAmount;

        if (beneficiaryAmount > 0 && payoutTo == address(0)) {
            payoutTo = s.feeRecipient;
        }
    }

    function _distributeLoop(
        GiveTypes.PayoutRouterState storage s,
        IERC20 token,
        bytes32 campaignId,
        address payoutRecipient,
        address vault,
        uint256 totalYield,
        uint256 totalShares
    ) private returns (YieldTotals memory totals) {
        for (uint256 i = 0; i < s.vaultShareholders[vault].length; i++) {
            address user = s.vaultShareholders[vault][i];
            uint256 userShares = s.userVaultShares[user][vault];
            if (userShares == 0) continue;

            uint256 userYield = (totalYield * userShares) / totalShares;
            if (userYield == 0) continue;

            (uint256 campaignAmt, uint256 benefAmt, uint256 protocolAmt) =
                _processUserYield(s, token, campaignId, payoutRecipient, vault, user, userYield);

            totals.campaign += campaignAmt;
            totals.beneficiary += benefAmt;
            totals.protocol += protocolAmt;
        }
    }

    function _processUserYield(
        GiveTypes.PayoutRouterState storage s,
        IERC20 token,
        bytes32 campaignId,
        address payoutRecipient,
        address vault,
        address user,
        uint256 userYield
    ) private returns (uint256 campaignAmount, uint256 beneficiaryAmount, uint256 protocolAmount) {
        address beneficiary;
        (campaignAmount, beneficiaryAmount, protocolAmount, beneficiary) =
            _calculateAllocations(s, campaignId, payoutRecipient, user, vault, userYield);

        if (beneficiaryAmount > 0) {
            token.safeTransfer(beneficiary, beneficiaryAmount);
            emit BeneficiaryPaid(user, vault, beneficiary, beneficiaryAmount);
        }
    }

    function _removeShareholder(GiveTypes.PayoutRouterState storage s, address vault, address user) private {
        address[] storage holders = s.vaultShareholders[vault];
        uint256 length = holders.length;
        for (uint256 i = 0; i < length; i++) {
            if (holders[i] == user) {
                if (i != length - 1) {
                    holders[i] = holders[length - 1];
                }
                holders.pop();
                break;
            }
        }
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
