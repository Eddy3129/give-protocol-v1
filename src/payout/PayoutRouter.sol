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

/**
 * @title   PayoutRouter
 * @author  GIVE Labs
 * @notice  Campaign-aware router that distributes harvested yield between campaigns,
 *          supporters, and the protocol treasury using a pull-based accumulator model.
 * @dev     Key Responsibilities:
 *          - Track per-user vault shares reported by authorized vault contracts
 *          - Accumulate yield per share as vaults harvest and record yield
 *          - Allow users to pull their accrued yield, split across campaign, beneficiary,
 *            and protocol fee buckets according to their stored preference
 *          - Enforce a timelocked fee-change mechanism to protect depositors
 *
 *          Architecture:
 *          - UUPS upgradeable proxy pattern
 *          - Dual-source ACL: external ACLManager checked first, local AccessControl as fallback
 *          - Pull-based accumulator: no unbounded loops during yield distribution
 *
 *          Yield Flow:
 *          1. Vault calls `updateUserShares` on deposit/withdrawal to sync share counts
 *          2. Vault calls `recordYield` after each harvest, depositing tokens and
 *             advancing the per-share accumulator
 *          3. Users call `claimYield` to pull their pro-rata share, distributed as:
 *             - Protocol fee (feeBps of gross yield) → protocolTreasury
 *             - Campaign portion (allocationPercentage of net yield) → campaign payoutRecipient
 *             - Beneficiary portion (remainder of net yield) → user-configured beneficiary
 *
 *          Fee Governance:
 *          - Fee decreases take effect immediately via `proposeFeeChange`
 *          - Fee increases are timelocked for FEE_CHANGE_DELAY (7 days)
 *          - Single increase capped at MAX_FEE_INCREASE_PER_CHANGE (250 bps = 2.5%)
 *          - Pending changes can be cancelled by FEE_MANAGER before execution
 *
 *          Security Model:
 *          - `recordYield` and `updateUserShares` restricted to authorizedCallers (vault contracts)
 *          - Campaign wiring restricted to VAULT_MANAGER_ROLE
 *          - Fee configuration restricted to FEE_MANAGER_ROLE
 *          - Emergency withdrawal restricted to DEFAULT_ADMIN_ROLE
 *          - Upgrade authority restricted to ROLE_UPGRADER via ACLManager
 *          - Reentrancy guard on `claimYield`
 */
contract PayoutRouter is
    Initializable,
    UUPSUpgradeable,
    AccessControlUpgradeable,
    ReentrancyGuardUpgradeable,
    PausableUpgradeable
{
    using SafeERC20 for IERC20;

    // ============================================
    // CONSTANTS
    // ============================================

    /// @notice Role required to register and reassign campaign-vault mappings
    bytes32 public constant VAULT_MANAGER_ROLE = keccak256("VAULT_MANAGER_ROLE");

    /// @notice Role required to propose and cancel protocol fee changes
    bytes32 public constant FEE_MANAGER_ROLE = keccak256("FEE_MANAGER_ROLE");

    /// @notice Role required to upgrade the contract implementation
    bytes32 public constant ROLE_UPGRADER = keccak256("ROLE_UPGRADER");

    /// @notice Maximum protocol fee in basis points (1 000 = 10%)
    uint256 public constant MAX_FEE_BPS = 1_000;

    /// @notice Fixed-point precision scalar used in per-share accumulator arithmetic
    uint256 private constant PRECISION = 1e18;

    /// @notice Minimum delay before a proposed fee increase takes effect (7 days)
    uint256 public constant FEE_CHANGE_DELAY = 7 days;

    /// @notice Maximum fee increase allowed in a single proposal, in basis points (250 = 2.5%)
    uint256 public constant MAX_FEE_INCREASE_PER_CHANGE = 250;

    // ============================================
    // ERRORS
    // ============================================

    /**
     * @notice Caller lacks the required role
     * @param roleId  Required role identifier
     * @param account Address that attempted the operation
     */
    error Unauthorized(bytes32 roleId, address account);

    /**
     * @notice Vault has not been registered with a campaign
     * @param vault Vault address that was looked up
     */
    error VaultNotRegistered(address vault);

    /**
     * @notice allocationPercentage is not one of the whitelisted values (50, 75, 100)
     * @param allocation The invalid value provided
     */
    error InvalidAllocation(uint8 allocation);

    /**
     * @notice A beneficiary address is required when allocationPercentage < 100
     */
    error InvalidBeneficiary();

    /**
     * @notice Stored preference campaignId does not match the vault's current campaign
     * @param expected campaignId currently assigned to the vault
     * @param provided campaignId stored in the user's preference
     */
    error CampaignMismatch(bytes32 expected, bytes32 provided);

    // ============================================
    // EVENTS
    // ============================================

    /**
     * @notice Emitted when a user updates their yield-split preference for a vault
     * @param user                 Address whose preference was updated
     * @param vault                Vault the preference applies to
     * @param campaignId           Campaign currently assigned to the vault
     * @param beneficiary          Address that receives the non-campaign portion of yield
     * @param allocationPercentage Percentage of net yield directed to the campaign (50, 75, or 100)
     */
    event YieldPreferenceUpdated(
        address indexed user,
        address indexed vault,
        bytes32 indexed campaignId,
        address beneficiary,
        uint8 allocationPercentage
    );

    /**
     * @notice Emitted when a vault reports an updated share count for a user
     * @param user        Address whose share balance changed
     * @param vault       Vault that reported the change
     * @param shares      New share balance for the user
     * @param totalShares New total share supply tracked for the vault
     */
    event UserSharesUpdated(address indexed user, address indexed vault, uint256 shares, uint256 totalShares);

    /**
     * @notice Emitted when a vault is wired to a campaign (including re-assignments)
     * @param vault      Vault address
     * @param campaignId Campaign the vault is now associated with
     */
    event CampaignVaultRegistered(address indexed vault, bytes32 indexed campaignId);

    /**
     * @notice Emitted on each successful yield claim, summarising campaign and protocol amounts
     * @param campaignId     Campaign that received the yield
     * @param vault          Vault the yield originated from
     * @param recipient      Campaign payout recipient address
     * @param campaignAmount Token amount transferred to the campaign
     * @param protocolAmount Token amount transferred to the protocol treasury
     */
    event CampaignPayoutExecuted(
        bytes32 indexed campaignId,
        address indexed vault,
        address recipient,
        uint256 campaignAmount,
        uint256 protocolAmount
    );

    /**
     * @notice Emitted when the beneficiary portion of a yield claim is transferred
     * @param user        Address that initiated the claim
     * @param vault       Vault the yield originated from
     * @param beneficiary Address that received the beneficiary portion
     * @param amount      Token amount transferred
     */
    event BeneficiaryPaid(address indexed user, address indexed vault, address beneficiary, uint256 amount);

    /**
     * @notice Emitted when a vault deposits yield tokens and advances the per-share accumulator
     * @param vault          Vault that recorded the yield
     * @param asset          ERC-20 token address
     * @param totalYield     Total token amount deposited
     * @param deltaPerShare  Accumulator increment (scaled by PRECISION)
     */
    event YieldRecorded(address indexed vault, address indexed asset, uint256 totalYield, uint256 deltaPerShare);

    /**
     * @notice Emitted after a user successfully claims their accrued yield
     * @param user              Address that claimed
     * @param vault             Vault the yield originated from
     * @param asset             ERC-20 token claimed
     * @param campaignAmount    Amount sent to the campaign
     * @param beneficiaryAmount Amount sent to the beneficiary
     * @param protocolAmount    Amount sent to the protocol treasury
     */
    event YieldClaimed(
        address indexed user,
        address indexed vault,
        address indexed asset,
        uint256 campaignAmount,
        uint256 beneficiaryAmount,
        uint256 protocolAmount
    );

    /**
     * @notice Emitted when a stale preference (pointing to a reassigned campaign) is auto-cleared
     * @param user  Address whose preference was cleared
     * @param vault Vault the preference was associated with
     */
    event StalePrefCleared(address indexed user, address indexed vault);

    /**
     * @notice Emitted when a vault is re-assigned from one campaign to another
     * @param vault        Vault address
     * @param oldCampaignId Previous campaign association
     * @param newCampaignId New campaign association
     */
    event VaultReassigned(address indexed vault, bytes32 indexed oldCampaignId, bytes32 indexed newCampaignId);

    /**
     * @notice Emitted when the fee configuration is updated (either via instant decrease or timelock execution)
     * @param oldRecipient Previous fee recipient
     * @param newRecipient New fee recipient
     * @param oldFeeBps    Previous fee in basis points
     * @param newFeeBps    New fee in basis points
     */
    event FeeConfigUpdated(
        address indexed oldRecipient, address indexed newRecipient, uint256 oldFeeBps, uint256 newFeeBps
    );

    /**
     * @notice Emitted when the protocol treasury address is changed
     * @param oldTreasury Previous treasury address
     * @param newTreasury New treasury address
     */
    event ProtocolTreasuryUpdated(address indexed oldTreasury, address indexed newTreasury);

    /**
     * @notice Emitted when a vault's authorized-caller status is toggled
     * @param caller     Vault address affected
     * @param authorized New authorization status
     */
    event AuthorizedCallerUpdated(address indexed caller, bool authorized);

    /**
     * @notice Emitted on an emergency token withdrawal by the admin
     * @param asset     Token withdrawn
     * @param recipient Destination address
     * @param amount    Amount withdrawn
     */
    event EmergencyWithdrawal(address indexed asset, address indexed recipient, uint256 amount);

    /**
     * @notice Emitted when a fee increase is placed in the timelock queue
     * @param nonce              Unique identifier for this pending change
     * @param recipient          Proposed new fee recipient
     * @param feeBps             Proposed new fee in basis points
     * @param effectiveTimestamp Unix timestamp after which the change can be executed
     */
    event FeeChangeProposed(
        uint256 indexed nonce, address indexed recipient, uint256 feeBps, uint256 effectiveTimestamp
    );

    /**
     * @notice Emitted when a timelocked fee change is executed
     * @param nonce      Nonce of the executed change
     * @param newFeeBps  Fee that is now active
     * @param newRecipient Recipient that is now active
     */
    event FeeChangeExecuted(uint256 indexed nonce, uint256 newFeeBps, address newRecipient);

    /**
     * @notice Emitted when a pending fee change is cancelled before execution
     * @param nonce Nonce of the cancelled change
     */
    event FeeChangeCancelled(uint256 indexed nonce);

    /**
     * @notice Emitted when the ACL manager reference is updated
     * @param previousManager Previously stored ACL manager address
     * @param newManager      Newly stored ACL manager address
     */
    event ACLManagerUpdated(address indexed previousManager, address indexed newManager);

    // ============================================
    // STRUCTS
    // ============================================

    /**
     * @notice Intermediate result of yield split calculations for a single claim
     * @param campaignAmount    Tokens allocated to the campaign payout recipient
     * @param beneficiaryAmount Tokens allocated to the user-configured beneficiary
     * @param protocolAmount    Tokens allocated to the protocol treasury (fee)
     * @param payoutTo          Resolved beneficiary address used for the beneficiary transfer
     */
    struct AllocationResult {
        uint256 campaignAmount;
        uint256 beneficiaryAmount;
        uint256 protocolAmount;
        address payoutTo;
    }

    /**
     * @notice Input bundle for `_calculateAllocations`, used to avoid stack-too-deep errors
     * @param campaignId          Campaign currently assigned to the vault
     * @param defaultBeneficiary  Campaign's payoutRecipient, used when the user has no preference
     * @param user                Address claiming yield
     * @param vault               Vault the yield originated from
     * @param userYield           Gross yield amount accrued to the user
     */
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
    /// @dev Checked before local AccessControl storage; set once during initialization
    IACLManager public aclManager;

    // ============================================
    // INITIALIZATION
    // ============================================

    /**
     * @notice Initializes the PayoutRouter with protocol addresses and fee configuration
     * @dev Can only be called once due to the `initializer` modifier.
     *      Sets DEFAULT_ADMIN_ROLE on admin_ for local AccessControl management.
     *      Valid allocation percentages are fixed at 50, 75, and 100 on construction.
     * @param admin_            Address granted DEFAULT_ADMIN_ROLE (pause/unpause/emergency)
     * @param acl_              Address of the protocol ACLManager contract
     * @param campaignRegistry_ Address of the CampaignRegistry contract
     * @param feeRecipient_     Initial address that receives protocol fees
     * @param protocolTreasury_ Address of the protocol treasury for fee transfers
     * @param feeBps_           Initial protocol fee in basis points (must be <= MAX_FEE_BPS)
     */
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

    // ============================================
    // VIEW HELPERS
    // ============================================

    /// @notice Returns the address of the CampaignRegistry contract
    function campaignRegistry() public view returns (address) {
        return _state().campaignRegistry;
    }

    /// @notice Returns the current fee recipient address
    function feeRecipient() public view returns (address) {
        return _state().feeRecipient;
    }

    /// @notice Returns the current protocol treasury address
    function protocolTreasury() public view returns (address) {
        return _state().protocolTreasury;
    }

    /// @notice Returns the current protocol fee in basis points
    function feeBps() public view returns (uint256) {
        return _state().feeBps;
    }

    /// @notice Returns the cumulative number of `recordYield` calls processed
    function totalDistributions() external view returns (uint256) {
        return _state().totalDistributions;
    }

    /**
     * @notice Returns whether an address is whitelisted as an authorized caller (vault)
     * @param caller Address to check
     * @return True if the address may call `recordYield` and `updateUserShares`
     */
    function authorizedCallers(address caller) external view returns (bool) {
        return _state().authorizedCallers[caller];
    }

    /// @notice Returns the three whitelisted yield-allocation percentages (50, 75, 100)
    function getValidAllocations() external view returns (uint8[3] memory) {
        return _state().validAllocations;
    }

    /**
     * @notice Returns the campaign ID currently wired to a vault
     * @param vault Vault address to look up
     * @return campaignId bytes32(0) if the vault has not been registered
     */
    function getVaultCampaign(address vault) external view returns (bytes32) {
        return _state().vaultCampaigns[vault];
    }

    /**
     * @notice Returns the stored yield-split preference for a user on a specific vault
     * @param user  Address of the depositor
     * @param vault Vault address
     * @return Struct containing campaignId, beneficiary, allocationPercentage, and lastUpdated
     */
    function getVaultPreference(address user, address vault)
        external
        view
        returns (GiveTypes.CampaignPreference memory)
    {
        return _state().userPreferences[user][vault];
    }

    /**
     * @notice Returns the share balance tracked by the router for a user in a vault
     * @param user  Address of the depositor
     * @param vault Vault address
     * @return Share count as reported by the vault via `updateUserShares`
     */
    function getUserVaultShares(address user, address vault) external view returns (uint256) {
        return _state().userVaultShares[user][vault];
    }

    /**
     * @notice Returns the total share supply tracked by the router for a vault
     * @param vault Vault address
     * @return Sum of all user share balances reported for the vault
     */
    function getTotalVaultShares(address vault) external view returns (uint256) {
        return _state().totalVaultShares[vault];
    }

    /**
     * @notice Returns all shareholders for a vault as an unbounded array
     * @dev WARNING: This array is unbounded. Do NOT call on-chain with large depositor sets.
     *      Use `getVaultShareholdersPaged` for on-chain or gas-sensitive contexts.
     * @param vault Vault address to query
     * @return Copy of the full shareholder list
     */
    function getVaultShareholders(address vault) external view returns (address[] memory) {
        GiveTypes.PayoutRouterState storage s = _state();
        address[] storage list = s.vaultShareholders[vault];
        address[] memory copy = new address[](list.length);
        for (uint256 i = 0; i < list.length; i++) {
            copy[i] = list[i];
        }
        return copy;
    }

    /**
     * @notice Returns a paginated slice of shareholders for a vault
     * @param vault   Vault address to query
     * @param offset  Start index (0-based)
     * @param limit   Maximum number of addresses to return
     * @return page   Slice of shareholder addresses
     * @return total  Total number of shareholders registered for the vault
     */
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

    /**
     * @notice Returns the lifetime payout totals for a campaign
     * @param campaignId Campaign to query
     * @return payouts      Cumulative tokens sent to the campaign payout recipient
     * @return protocolFees Cumulative protocol fees charged against this campaign's yield
     */
    function getCampaignTotals(bytes32 campaignId) external view returns (uint256 payouts, uint256 protocolFees) {
        GiveTypes.PayoutRouterState storage s = _state();
        return (s.campaignTotalPayouts[campaignId], s.campaignProtocolFees[campaignId]);
    }

    /**
     * @notice Returns the total pending yield claimable by a user from a vault for a given asset
     * @dev Combines already-settled `pendingYield` with newly accrued yield since the last
     *      debt checkpoint, without writing state.
     * @param user  Address of the depositor
     * @param vault Vault address
     * @param asset ERC-20 token address
     * @return Total claimable token amount
     */
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

    // ============================================
    // ROLE-MANAGED CONFIGURATION
    // ============================================

    /**
     * @notice Adds or removes a vault from the authorized-callers whitelist
     * @dev Authorized callers may invoke `recordYield` and `updateUserShares`.
     *      Requires VAULT_MANAGER_ROLE.
     * @param caller     Vault address to authorize or de-authorize
     * @param authorized True to grant access, false to revoke
     */
    function setAuthorizedCaller(address caller, bool authorized) external onlyRole(VAULT_MANAGER_ROLE) {
        if (caller == address(0)) revert GiveErrors.ZeroAddress();
        _state().authorizedCallers[caller] = authorized;
        emit AuthorizedCallerUpdated(caller, authorized);
    }

    /**
     * @notice Propose a fee configuration change (subject to timelock for increases)
     * @dev Fee decreases take effect immediately.
     *      Fee increases are queued with a FEE_CHANGE_DELAY timelock and capped at
     *      MAX_FEE_INCREASE_PER_CHANGE per proposal.
     *      Requires FEE_MANAGER_ROLE.
     * @param newRecipient New address to receive protocol fees
     * @param newFeeBps    New fee in basis points (must be <= MAX_FEE_BPS)
     */
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

    /**
     * @notice Execute a pending fee change after its timelock has expired
     * @dev Permissionless — anyone may call once the delay has passed.
     *      Deletes the pending change entry after applying the new values.
     * @param nonce The fee change nonce returned by the corresponding `FeeChangeProposed` event
     */
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

    /**
     * @notice Cancel a pending fee change before it is executed
     * @dev Requires FEE_MANAGER_ROLE. Can be called at any time before execution.
     * @param nonce The fee change nonce to cancel
     */
    function cancelFeeChange(uint256 nonce) external onlyRole(FEE_MANAGER_ROLE) {
        GiveTypes.PayoutRouterState storage s = _state();
        GiveTypes.PendingFeeChange storage change = s.pendingFeeChanges[nonce];

        if (!change.exists) {
            revert GiveErrors.FeeChangeNotFound(nonce);
        }

        delete s.pendingFeeChanges[nonce];
        emit FeeChangeCancelled(nonce);
    }

    /**
     * @notice Get the details of a pending fee change
     * @param nonce              The fee change nonce to look up
     * @return newFeeBps         Proposed new fee in basis points
     * @return newRecipient      Proposed new fee recipient
     * @return effectiveTimestamp Unix timestamp after which the change can be executed
     * @return exists            False if the nonce does not correspond to a live pending change
     */
    function getPendingFeeChange(uint256 nonce)
        external
        view
        returns (uint256 newFeeBps, address newRecipient, uint256 effectiveTimestamp, bool exists)
    {
        GiveTypes.PendingFeeChange storage change = _state().pendingFeeChanges[nonce];
        return (change.newFeeBps, change.newRecipient, change.effectiveTimestamp, change.exists);
    }

    /**
     * @notice Check whether a pending fee change is past its timelock and ready to execute
     * @param nonce The fee change nonce to check
     * @return ready True if the change exists and `block.timestamp >= effectiveTimestamp`
     */
    function isFeeChangeReady(uint256 nonce) external view returns (bool ready) {
        GiveTypes.PendingFeeChange storage change = _state().pendingFeeChanges[nonce];
        return change.exists && block.timestamp >= change.effectiveTimestamp;
    }

    /**
     * @notice Update the protocol treasury address
     * @dev Requires FEE_MANAGER_ROLE.
     * @param newTreasury New treasury address (must be non-zero)
     */
    function setProtocolTreasury(address newTreasury) external onlyRole(FEE_MANAGER_ROLE) {
        if (newTreasury == address(0)) revert GiveErrors.ZeroAddress();
        GiveTypes.PayoutRouterState storage s = _state();
        address oldTreasury = s.protocolTreasury;
        s.protocolTreasury = newTreasury;
        emit ProtocolTreasuryUpdated(oldTreasury, newTreasury);
    }

    /**
     * @notice Pause the contract, disabling `setVaultPreference`, `recordYield`, and `claimYield`
     * @dev Requires DEFAULT_ADMIN_ROLE.
     */
    function pause() external onlyRole(DEFAULT_ADMIN_ROLE) {
        _pause();
    }

    /**
     * @notice Unpause the contract, re-enabling user-facing operations
     * @dev Requires DEFAULT_ADMIN_ROLE.
     */
    function unpause() external onlyRole(DEFAULT_ADMIN_ROLE) {
        _unpause();
    }

    // ============================================
    // CAMPAIGN WIRING
    // ============================================

    /**
     * @notice Wire a vault to a campaign, or reassign it to a different campaign
     * @dev Requires VAULT_MANAGER_ROLE.
     *      Emits `VaultReassigned` in addition to `CampaignVaultRegistered` when overwriting
     *      an existing non-zero campaign mapping.
     * @param vault      Vault address to register (must be non-zero)
     * @param campaignId Campaign to associate with the vault (must be non-zero)
     */
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

    // ============================================
    // PREFERENCES
    // ============================================

    /**
     * @notice Set the caller's yield-split preference for a vault
     * @dev Vault must already be registered with a campaign.
     *      allocationPercentage must be one of the whitelisted values (50, 75, 100).
     *      A beneficiary address is required when allocationPercentage < 100.
     *      Callable by any user; paused when contract is paused.
     * @param vault                Vault the preference applies to
     * @param beneficiary          Address to receive the non-campaign portion (ignored when 100%)
     * @param allocationPercentage Percentage of net yield directed to the campaign
     */
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

    // ============================================
    // SHARE TRACKING
    // ============================================

    /**
     * @notice Report a user's updated vault share balance to the router
     * @dev Called by authorized vault contracts on every deposit or withdrawal.
     *      Accrues pending yield across all registered assets for the user before
     *      applying the new share count to avoid yield miscalculation.
     *      `msg.sender` is treated as the vault address.
     * @param user      Address whose share balance changed
     * @param newShares Updated share balance (0 on full withdrawal)
     */
    function updateUserShares(address user, uint256 newShares) external onlyAuthorized {
        GiveTypes.PayoutRouterState storage s = _state();
        address vault = msg.sender;

        _syncUserPendingAcrossAssets(s, vault, user);

        uint256 oldShares = s.userVaultShares[user][vault];
        s.userVaultShares[user][vault] = newShares;
        s.totalVaultShares[vault] = s.totalVaultShares[vault] - oldShares + newShares;

        emit UserSharesUpdated(user, vault, newShares, s.totalVaultShares[vault]);
    }

    // ============================================
    // YIELD DISTRIBUTION
    // ============================================

    /**
     * @notice Record a yield deposit and advance the per-share accumulator for a vault
     * @dev Called by authorized vault contracts after transferring `totalYield` tokens to
     *      this contract. The per-share delta is computed and added to the accumulator so
     *      all existing shareholders accrue proportionally.
     *      Reverts if the campaign has `payoutsHalted` set, if totalShares is zero, or if
     *      the contract's token balance is insufficient.
     *      `msg.sender` is treated as the vault address.
     * @param asset      ERC-20 token address of the yield
     * @param totalYield Amount of tokens being recorded (must be > 0)
     * @return The recorded yield amount (echoes `totalYield`)
     */
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

    /**
     * @notice Claim all accrued yield for the caller from a vault for a specific asset
     * @dev Settles the caller's pending yield, resolves their allocation preference,
     *      and executes the three-way split transfer in a single transaction.
     *      Stale preferences (pointing to a reassigned campaign) are auto-cleared.
     *      Returns 0 without reverting when no yield is available.
     *      Protected by `nonReentrant` and `whenNotPaused`.
     * @param vault Vault to claim yield from
     * @param asset ERC-20 token to claim (must be non-zero)
     * @return Total tokens distributed (campaign + beneficiary + protocol amounts)
     */
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

    /**
     * @notice Emergency withdrawal of any ERC-20 token held by this contract
     * @dev Intended for recovering tokens sent by mistake or after a contract migration.
     *      Requires DEFAULT_ADMIN_ROLE.
     * @param asset     Token address to withdraw (must be non-zero)
     * @param recipient Destination address (must be non-zero)
     * @param amount    Amount of tokens to transfer
     */
    function emergencyWithdraw(address asset, address recipient, uint256 amount) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (asset == address(0) || recipient == address(0)) {
            revert GiveErrors.ZeroAddress();
        }
        IERC20(asset).safeTransfer(recipient, amount);
        emit EmergencyWithdrawal(asset, recipient, amount);
    }

    // ============================================
    // INTERNAL HELPERS
    // ============================================

    /**
     * @notice Compute the three-way yield split for a claim
     * @dev Protocol fee is taken from gross yield first; the remainder is split between the
     *      campaign and beneficiary according to allocationPercentage. When no preference is
     *      set, defaults to 100% campaign allocation. When beneficiaryAmount > 0 but no
     *      beneficiary is resolvable, falls back to feeRecipient.
     * @param s Payout router state slot
     * @param p Bundled claim parameters
     * @return allocation Populated AllocationResult with amounts and resolved payoutTo address
     */
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

    /**
     * @notice Execute the three ERC-20 transfers for a resolved allocation
     * @dev Transfers protocol fee, campaign amount, and beneficiary amount in that order.
     *      Skips any transfer with a zero amount to avoid unnecessary gas and events.
     * @param s                 Payout router state slot
     * @param asset             ERC-20 token to transfer
     * @param campaignId        Campaign ID for accounting updates
     * @param campaignRecipient Campaign payout recipient address
     * @param user              Claimant address (used for event attribution)
     * @param vault             Source vault address (used for event attribution)
     * @param allocation        Pre-computed split amounts and resolved payoutTo
     */
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

    /**
     * @notice Accrue pending yield for a user across all assets ever recorded for a vault
     * @dev Called before share updates to ensure the user's debt checkpoint is current
     *      for every asset, preventing yield loss on deposit/withdrawal.
     * @param s     Payout router state slot
     * @param vault Vault to iterate assets for
     * @param user  Address to settle pending yield for
     */
    function _syncUserPendingAcrossAssets(GiveTypes.PayoutRouterState storage s, address vault, address user) private {
        address[] storage assets = s.vaultAssets[vault];
        for (uint256 i = 0; i < assets.length; i++) {
            _accruePending(s, vault, assets[i], user);
        }
    }

    /**
     * @notice Settle any unrecorded yield for a user since their last debt checkpoint
     * @dev Computes `shares * (acc - debt) / PRECISION` and adds it to `pendingYield`,
     *      then advances the debt pointer to `acc`. Safe to call when shares == 0 or
     *      acc == debt (no-op for the accrual, still updates the debt pointer).
     * @param s     Payout router state slot
     * @param vault Vault the yield belongs to
     * @param asset ERC-20 token to accrue
     * @param user  Address to settle
     */
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

    /**
     * @notice Register an asset as one that has been recorded for a vault (idempotent)
     * @dev Prevents duplicate entries in `vaultAssets[vault]` by checking `hasVaultAsset`
     *      before appending. Called once per unique (vault, asset) pair.
     * @param s     Payout router state slot
     * @param vault Vault to register the asset under
     * @param asset ERC-20 token address to register
     */
    function _registerVaultAsset(GiveTypes.PayoutRouterState storage s, address vault, address asset) private {
        if (s.hasVaultAsset[vault][asset]) {
            return;
        }
        s.hasVaultAsset[vault][asset] = true;
        s.vaultAssets[vault].push(asset);
    }

    /**
     * @notice Look up the campaign ID for a vault, reverting if the vault is unregistered
     * @param s     Payout router state slot
     * @param vault Vault address to look up
     * @return campaignId Non-zero campaign ID associated with the vault
     */
    function _requireCampaignForVault(GiveTypes.PayoutRouterState storage s, address vault)
        private
        view
        returns (bytes32)
    {
        bytes32 campaignId = s.vaultCampaigns[vault];
        if (campaignId == bytes32(0)) revert VaultNotRegistered(vault);
        return campaignId;
    }

    /**
     * @notice Check whether an allocation percentage is in the whitelisted set
     * @param s          Payout router state slot
     * @param allocation Value to validate
     * @return True if `allocation` matches one of the three stored valid values
     */
    function _isValidAllocation(GiveTypes.PayoutRouterState storage s, uint8 allocation) private view returns (bool) {
        for (uint256 i = 0; i < s.validAllocations.length; i++) {
            if (s.validAllocations[i] == allocation) return true;
        }
        return false;
    }

    /// @dev Returns the diamond storage slot for PayoutRouterState
    function _state() private view returns (GiveTypes.PayoutRouterState storage) {
        return StorageLib.payoutRouter();
    }

    // ============================================
    // MODIFIERS
    // ============================================

    /**
     * @notice Restricts access to addresses registered as authorized callers (vault contracts)
     * @dev Reverts with `GiveErrors.UnauthorizedCaller` if `msg.sender` is not whitelisted
     */
    modifier onlyAuthorized() {
        if (!_state().authorizedCallers[msg.sender]) {
            revert GiveErrors.UnauthorizedCaller(msg.sender);
        }
        _;
    }

    // ============================================
    // UPGRADEABILITY
    // ============================================

    /**
     * @notice Authorizes contract upgrades
     * @dev Called by UUPSUpgradeable during the upgrade process.
     *      Only addresses with ROLE_UPGRADER (checked via ACLManager) may upgrade.
     */
    function _authorizeUpgrade(address) internal view override {
        if (!aclManager.hasRole(ROLE_UPGRADER, msg.sender)) {
            revert Unauthorized(ROLE_UPGRADER, msg.sender);
        }
    }

    /**
     * @notice Update the ACL manager reference
     * @dev Internal; called during `initialize`. Reverts on zero address.
     * @param acl New ACL manager address
     */
    function _setACLManager(address acl) internal {
        if (acl == address(0)) revert GiveErrors.ZeroAddress();
        address previous = address(aclManager);
        aclManager = IACLManager(acl);
        emit ACLManagerUpdated(previous, acl);
    }

    /**
     * @notice Override role check to delegate to the ACL manager with local fallback
     * @dev Implements dual-source role checking:
     *      1. Checks the external ACL manager first (if set and account has the role)
     *      2. Falls back to local AccessControl storage
     * @param role    The role identifier to check
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
