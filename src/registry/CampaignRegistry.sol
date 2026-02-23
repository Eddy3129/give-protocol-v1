// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

import "../interfaces/IACLManager.sol";
import "../storage/StorageLib.sol";
import "../types/GiveTypes.sol";

/**
 * @notice Interface for StrategyRegistry contract
 * @dev Used to validate strategies during campaign submission
 */
interface IStrategyRegistry {
    function getStrategy(bytes32 strategyId) external view returns (GiveTypes.StrategyConfig memory);
}

/**
 * @notice Interface for NGORegistry contract
 * @dev Used to validate NGO approval and campaign submission delegation
 */
interface INGORegistry {
    function isApproved(address ngo) external view returns (bool);
    function canSubmitCampaignFor(address ngo, address submitter) external view returns (bool);
}

/**
 * @title CampaignRegistry
 * @author GIVE Labs
 * @notice Canonical registry for campaign lifecycle, governance, and supporter stake management
 * @dev Manages campaign submission, approval/rejection, curator assignments, checkpoints, voting,
 *      and stake escrow. This is the core orchestration layer for the GIVE protocol.
 *
 *      Key Features:
 *      - Campaign submission with anti-spam deposit (0.005 ETH)
 *      - Approval/rejection flow with deposit refund/slash (H-01 fix)
 *      - Curator-based campaign management
 *      - Supporter stake tracking (deposits, exits, voting power)
 *      - Checkpoint-based governance with quorum voting
 *      - Flash loan protection (MIN_STAKE_DURATION)
 *      - Payout halt mechanism on failed checkpoints
 *      - UUPS upgradeability
 *
 *      Campaign Lifecycle:
 *      1. Submitted → proposer pays 0.005 ETH deposit
 *      2. Approved → deposit refunded, curator assigned
 *      3. Rejected → deposit slashed (kept by protocol)
 *      4. Fundraising → supporters stake funds
 *      5. Active → yield generation begins
 *      6. Checkpoints → periodic governance votes
 *      7. Completed/Cancelled → final state
 *
 *      Security Model:
 *      - CAMPAIGN_ADMIN can approve/reject campaigns, manage lifecycle
 *      - CHECKPOINT_COUNCIL can update checkpoint status
 *      - CAMPAIGN_CURATOR can record stakes and exits
 *      - Flash loan protection via MIN_STAKE_DURATION (1 hour)
 *      - Deposit refund on approval prevents fund lock (H-01 fix)
 *      - Deposit slash on rejection discourages spam
 */
contract CampaignRegistry is Initializable, UUPSUpgradeable {
    // ============================================
    // STATE VARIABLES
    // ============================================

    /**
     * @notice ACL manager for role-based access control
     * @dev All admin operations check roles via this contract
     */
    IACLManager public aclManager;

    /**
     * @notice Strategy registry for validating campaign strategies
     * @dev Campaigns must use Active or FadingOut strategies (not Deprecated)
     */
    address public strategyRegistry;

    /**
     * @notice NGO registry for campaign submission authorization
     * @dev Optional hard gate. When configured, submitter must be authorized for approved NGO payout recipient.
     */
    address public ngoRegistry;

    /**
     * @notice Role identifier for contract upgrades
     * @dev Must match ACLManager.ROLE_UPGRADER
     */
    bytes32 public constant ROLE_UPGRADER = keccak256("ROLE_UPGRADER");

    /**
     * @notice Minimum ETH deposit required to submit a campaign
     * @dev Anti-spam mechanism. Refunded on approval, slashed on rejection.
     */
    uint256 public constant MIN_SUBMISSION_DEPOSIT = 0.005 ether;

    /**
     * @notice Minimum duration a stake must exist before voting eligibility
     * @dev Flash loan protection. Prevents flash loan attacks by requiring 1-hour stake commitment.
     */
    uint64 public constant MIN_STAKE_DURATION = 1 hours;

    /**
     * @notice Enumerable list of all campaign IDs
     * @dev Used for iteration and discovery. Order is insertion order.
     */
    bytes32[] private _campaignIds;

    // ============================================
    // STRUCTS
    // ============================================

    /**
     * @notice Input parameters for campaign submission
     * @dev Separate from storage struct to avoid stack-too-deep errors
     */
    struct CampaignInput {
        bytes32 id; // Unique campaign identifier (keccak256 hash)
        address payoutRecipient; // NGO/recipient address for yield payouts
        bytes32 strategyId; // Strategy identifier (must exist in StrategyRegistry)
        bytes32 metadataHash; // Hash of campaign metadata for integrity
        string metadataCID; // IPFS CID for campaign details (name, description, images)
        uint256 targetStake; // Fundraising goal in asset units
        uint256 minStake; // Minimum stake required to activate campaign
        uint64 fundraisingStart; // Timestamp when fundraising begins
        uint64 fundraisingEnd; // Timestamp when fundraising ends (0 = no end)
    }

    /**
     * @notice Input parameters for checkpoint scheduling
     * @dev Checkpoints are periodic governance votes for campaign oversight
     */
    struct CheckpointInput {
        uint64 windowStart; // Timestamp when voting opens
        uint64 windowEnd; // Timestamp when voting closes
        uint64 executionDeadline; // Deadline for executing checkpoint result
        uint16 quorumBps; // Quorum requirement in basis points (e.g., 2000 = 20%)
    }

    // ============================================
    // EVENTS
    // ============================================

    /**
     * @notice Emitted when a campaign is submitted
     * @param id Campaign identifier
     * @param proposer Address that submitted the campaign
     * @param metadataHash Hash of campaign metadata
     * @param metadataCID IPFS CID for campaign details
     * @param depositAmount ETH deposit paid (MIN_SUBMISSION_DEPOSIT)
     */
    event CampaignSubmitted(
        bytes32 indexed id, address indexed proposer, bytes32 metadataHash, string metadataCID, uint256 depositAmount
    );

    /**
     * @notice Emitted when a campaign is approved
     * @param id Campaign identifier
     * @param curator Address assigned as campaign curator
     */
    event CampaignApproved(bytes32 indexed id, address indexed curator);

    /**
     * @notice Emitted when a campaign is rejected
     * @param id Campaign identifier
     * @param reason Rejection reason
     */
    event CampaignRejected(bytes32 indexed id, string reason);

    /**
     * @notice Emitted when a campaign's status changes
     * @param id Campaign identifier
     * @param previousStatus Old status
     * @param newStatus New status
     */
    event CampaignStatusChanged(
        bytes32 indexed id, GiveTypes.CampaignStatus previousStatus, GiveTypes.CampaignStatus newStatus
    );

    /**
     * @notice Emitted when submission deposit is refunded
     * @param id Campaign identifier
     * @param recipient Address receiving refund (original proposer)
     * @param amount ETH amount refunded
     */
    event DepositRefunded(bytes32 indexed id, address indexed recipient, uint256 amount);

    /**
     * @notice Emitted when submission deposit is slashed
     * @param id Campaign identifier
     * @param amount ETH amount slashed (kept by protocol)
     */
    event DepositSlashed(bytes32 indexed id, uint256 amount);

    /**
     * @notice Emitted when payout recipient is updated
     * @param id Campaign identifier
     * @param previousRecipient Old recipient address
     * @param newRecipient New recipient address
     */
    event PayoutRecipientUpdated(bytes32 indexed id, address indexed previousRecipient, address indexed newRecipient);

    /**
     * @notice Emitted when stake is deposited
     * @param id Campaign identifier
     * @param supporter Address of supporter
     * @param amount Amount deposited
     * @param totalStaked Total campaign stake after deposit
     */
    event StakeDeposited(bytes32 indexed id, address indexed supporter, uint256 amount, uint256 totalStaked);

    /**
     * @notice Emitted when stake exit is requested
     * @param id Campaign identifier
     * @param supporter Address of supporter
     * @param amountRequested Amount requested for withdrawal
     */
    event StakeExitRequested(bytes32 indexed id, address indexed supporter, uint256 amountRequested);

    /**
     * @notice Emitted when stake exit is finalized
     * @param id Campaign identifier
     * @param supporter Address of supporter
     * @param amountWithdrawn Amount withdrawn
     * @param remainingStake Remaining stake after withdrawal
     */
    event StakeExitFinalized(
        bytes32 indexed id, address indexed supporter, uint256 amountWithdrawn, uint256 remainingStake
    );

    /**
     * @notice Emitted when locked stake amount is updated
     * @param id Campaign identifier
     * @param previousAmount Old locked amount
     * @param newAmount New locked amount
     */
    event LockedStakeUpdated(bytes32 indexed id, uint256 previousAmount, uint256 newAmount);

    /**
     * @notice Emitted when a vault is registered to a campaign
     * @param campaignId Campaign identifier
     * @param vault Vault address
     * @param lockProfile Lock profile identifier
     */
    event CampaignVaultRegistered(bytes32 indexed campaignId, address indexed vault, bytes32 lockProfile);

    /**
     * @notice Emitted when a checkpoint is scheduled
     * @param campaignId Campaign identifier
     * @param index Checkpoint index
     * @param start Voting window start timestamp
     * @param end Voting window end timestamp
     * @param quorumBps Quorum requirement in basis points
     */
    event CheckpointScheduled(bytes32 indexed campaignId, uint256 index, uint64 start, uint64 end, uint16 quorumBps);

    /**
     * @notice Emitted when checkpoint status changes
     * @param campaignId Campaign identifier
     * @param index Checkpoint index
     * @param previousStatus Old status
     * @param newStatus New status
     */
    event CheckpointStatusUpdated(
        bytes32 indexed campaignId,
        uint256 index,
        GiveTypes.CheckpointStatus previousStatus,
        GiveTypes.CheckpointStatus newStatus
    );

    /**
     * @notice Emitted when a vote is cast on a checkpoint
     * @param campaignId Campaign identifier
     * @param index Checkpoint index
     * @param supporter Address of voter
     * @param support True if voting in favor, false if against
     * @param weight Voting power (stake amount)
     */
    event CheckpointVoteCast(
        bytes32 indexed campaignId, uint256 index, address indexed supporter, bool support, uint208 weight
    );

    /**
     * @notice Emitted when payouts are halted or resumed
     * @param campaignId Campaign identifier
     * @param halted True if halted, false if resumed
     */
    event PayoutsHalted(bytes32 indexed campaignId, bool halted);

    /**
     * @notice Emitted when NGO registry address is updated
     * @param previousRegistry Previous NGO registry address
     * @param newRegistry New NGO registry address
     */
    event NGORegistryUpdated(address indexed previousRegistry, address indexed newRegistry);

    // ============================================
    // ERRORS
    // ============================================

    /// @notice Zero address provided where non-zero required
    error ZeroAddress();

    /// @notice Caller lacks required role
    error Unauthorized(bytes32 roleId, address account);

    /// @notice Campaign ID already exists
    error CampaignAlreadyExists(bytes32 id);

    /// @notice Campaign ID not found
    error CampaignNotFound(bytes32 id);

    /// @notice Invalid campaign configuration parameters
    error InvalidCampaignConfig(bytes32 id);

    /// @notice Invalid campaign status for this operation
    error InvalidCampaignStatus(bytes32 id, GiveTypes.CampaignStatus status);

    /// @notice Invalid stake amount (zero or exceeds balance)
    error InvalidStakeAmount();

    /// @notice Insufficient submission deposit
    error InsufficientSubmissionDeposit(uint256 required, uint256 provided);

    /// @notice Supporter has no stake or insufficient stake
    error SupporterStakeMissing(address supporter);

    /// @notice Checkpoint not found
    error CheckpointNotFound(bytes32 id, uint256 index);

    /// @notice Invalid checkpoint window configuration
    error InvalidCheckpointWindow();

    /// @notice Invalid checkpoint status
    error InvalidCheckpointStatus(GiveTypes.CheckpointStatus status);

    /// @notice Strategy registry not configured
    error StrategyRegistryNotConfigured();

    /// @notice NGO registry not configured
    error NGORegistryNotConfigured();

    /// @notice Payout recipient NGO is not approved
    error NGONotApproved(address ngo);

    /// @notice Submitter is not authorized to submit on behalf of payout NGO
    error UnauthorizedCampaignSubmitter(address ngo, address submitter);

    /// @notice Supporter has already voted on this checkpoint
    error AlreadyVoted(address supporter);

    /// @notice Supporter has no voting power
    error NoVotingPower(address supporter);

    /// @notice ETH transfer failed
    error DepositTransferFailed();

    // ============================================
    // MODIFIERS
    // ============================================

    /**
     * @notice Restricts access to accounts with specific role
     * @dev Reverts if caller does not have the required role
     * @param roleId The role to check
     */
    modifier onlyRole(bytes32 roleId) {
        _onlyRole(roleId);
        _;
    }

    function _onlyRole(bytes32 roleId) internal view {
        if (!aclManager.hasRole(roleId, msg.sender)) {
            revert Unauthorized(roleId, msg.sender);
        }
    }

    // ============================================
    // INITIALIZATION
    // ============================================

    /**
     * @notice Initializes the campaign registry
     * @dev Only callable once due to initializer modifier.
     *      Sets up ACL manager and strategy registry references.
     * @param acl Address of ACLManager contract
     * @param strategyRegistry_ Address of StrategyRegistry contract
     */
    function initialize(address acl, address strategyRegistry_) external initializer {
        if (acl == address(0) || strategyRegistry_ == address(0)) {
            revert ZeroAddress();
        }
        aclManager = IACLManager(acl);
        strategyRegistry = strategyRegistry_;
    }

    // ============================================
    // EXTERNAL FUNCTIONS - CAMPAIGN LIFECYCLE
    // ============================================

    /**
     * @notice Submits a new campaign for review
     * @dev Requires MIN_SUBMISSION_DEPOSIT (0.005 ETH) as anti-spam measure.
     *      Campaign starts in Submitted status.
     *      Validates all input parameters and strategy existence.
     *      Deposit is refunded on approval or slashed on rejection.
     * @param input Campaign configuration parameters
     */
    function submitCampaign(CampaignInput calldata input) external payable {
        if (msg.value < MIN_SUBMISSION_DEPOSIT) {
            revert InsufficientSubmissionDeposit(MIN_SUBMISSION_DEPOSIT, msg.value);
        }

        _validateCampaignInput(input);
        _fetchStrategy(input.strategyId, input.id);
        _validateSubmissionAuthorization(input.payoutRecipient, msg.sender);

        GiveTypes.CampaignConfig storage cfg = StorageLib.campaign(input.id);
        if (cfg.exists) revert CampaignAlreadyExists(input.id);

        cfg.id = input.id;
        cfg.proposer = msg.sender;
        cfg.payoutRecipient = input.payoutRecipient;
        cfg.strategyId = input.strategyId;
        cfg.metadataHash = input.metadataHash;
        cfg.targetStake = input.targetStake;
        cfg.minStake = input.minStake;
        cfg.initialDeposit = msg.value;
        cfg.fundraisingStart = input.fundraisingStart;
        cfg.fundraisingEnd = input.fundraisingEnd;
        cfg.createdAt = uint64(block.timestamp);
        cfg.updatedAt = uint64(block.timestamp);
        cfg.status = GiveTypes.CampaignStatus.Submitted;
        cfg.exists = true;

        _campaignIds.push(input.id);

        emit CampaignSubmitted(input.id, msg.sender, input.metadataHash, input.metadataCID, msg.value);
    }

    /**
     * @notice Approves a submitted campaign and assigns a curator
     * @dev Only callable by CAMPAIGN_ADMIN.
     *      Refunds submission deposit to proposer (H-01 fix).
     *      Changes status from Submitted to Approved.
     * @param campaignId Campaign identifier
     * @param curator Address to assign as campaign curator
     */
    function approveCampaign(bytes32 campaignId, address curator) external onlyRole(aclManager.campaignAdminRole()) {
        if (curator == address(0)) revert ZeroAddress();

        GiveTypes.CampaignConfig storage cfg = _requireCampaign(campaignId);
        if (cfg.status != GiveTypes.CampaignStatus.Submitted) {
            revert InvalidCampaignStatus(campaignId, cfg.status);
        }

        cfg.curator = curator;
        cfg.status = GiveTypes.CampaignStatus.Approved;
        cfg.updatedAt = uint64(block.timestamp);

        // H-01 FIX: Refund deposit to proposer on approval
        uint256 depositAmount = cfg.initialDeposit;
        address proposer = cfg.proposer;

        if (depositAmount > 0) {
            cfg.initialDeposit = 0; // Zero out before transfer to prevent reentrancy
            (bool success,) = proposer.call{value: depositAmount}("");
            if (!success) revert DepositTransferFailed();
            emit DepositRefunded(campaignId, proposer, depositAmount);
        }

        emit CampaignApproved(campaignId, curator);
        emit CampaignStatusChanged(campaignId, GiveTypes.CampaignStatus.Submitted, GiveTypes.CampaignStatus.Approved);
    }

    /**
     * @notice Rejects a submitted campaign
     * @dev Only callable by CAMPAIGN_ADMIN.
     *      Slashes submission deposit (keeps in contract) (H-01 fix).
     *      Changes status from Submitted to Rejected.
     * @param campaignId Campaign identifier
     * @param reason Rejection reason for transparency
     */
    function rejectCampaign(bytes32 campaignId, string calldata reason)
        external
        onlyRole(aclManager.campaignAdminRole())
    {
        GiveTypes.CampaignConfig storage cfg = _requireCampaign(campaignId);
        if (cfg.status != GiveTypes.CampaignStatus.Submitted) {
            revert InvalidCampaignStatus(campaignId, cfg.status);
        }

        cfg.status = GiveTypes.CampaignStatus.Rejected;
        cfg.updatedAt = uint64(block.timestamp);

        // H-01 FIX: Slash deposit (keep in contract) on rejection
        uint256 depositAmount = cfg.initialDeposit;
        if (depositAmount > 0) {
            cfg.initialDeposit = 0; // Mark as slashed
            emit DepositSlashed(campaignId, depositAmount);
        }

        emit CampaignRejected(campaignId, reason);
        emit CampaignStatusChanged(campaignId, GiveTypes.CampaignStatus.Submitted, GiveTypes.CampaignStatus.Rejected);
    }

    /**
     * @notice Updates a campaign's status
     * @dev Only callable by CAMPAIGN_ADMIN.
     *      Cannot set status to Unknown.
     *      Idempotent (no-op if status unchanged).
     * @param campaignId Campaign identifier
     * @param newStatus New lifecycle status
     */
    function setCampaignStatus(bytes32 campaignId, GiveTypes.CampaignStatus newStatus)
        external
        onlyRole(aclManager.campaignAdminRole())
    {
        if (newStatus == GiveTypes.CampaignStatus.Unknown) {
            revert InvalidCampaignStatus(campaignId, newStatus);
        }

        GiveTypes.CampaignConfig storage cfg = _requireCampaign(campaignId);
        GiveTypes.CampaignStatus previous = cfg.status;
        if (previous == newStatus) return; // Idempotent

        cfg.status = newStatus;
        cfg.updatedAt = uint64(block.timestamp);

        emit CampaignStatusChanged(campaignId, previous, newStatus);
    }

    /**
     * @notice Updates payout recipient for a campaign
     * @dev Only callable by CAMPAIGN_ADMIN.
     *      Useful for NGO address changes or corrections.
     * @param campaignId Campaign identifier
     * @param recipient New payout recipient address
     */
    function setPayoutRecipient(bytes32 campaignId, address recipient)
        external
        onlyRole(aclManager.campaignAdminRole())
    {
        if (recipient == address(0)) revert ZeroAddress();

        GiveTypes.CampaignConfig storage cfg = _requireCampaign(campaignId);
        address previous = cfg.payoutRecipient;
        cfg.payoutRecipient = recipient;
        cfg.updatedAt = uint64(block.timestamp);

        emit PayoutRecipientUpdated(campaignId, previous, recipient);
    }

    /**
     * @notice Registers a vault to a campaign
     * @dev Only callable by CAMPAIGN_ADMIN.
     *      Links campaign to its yield-generating vault.
     *      Creates bidirectional mapping (campaign→vault and vault→campaign).
     * @param campaignId Campaign identifier
     * @param vault Vault address
     * @param lockProfile Lock profile identifier for vault configuration
     */
    function setCampaignVault(bytes32 campaignId, address vault, bytes32 lockProfile)
        external
        onlyRole(aclManager.campaignAdminRole())
    {
        if (vault == address(0)) revert ZeroAddress();

        GiveTypes.CampaignConfig storage cfg = _requireCampaign(campaignId);
        cfg.vault = vault;
        cfg.lockProfile = lockProfile;
        cfg.updatedAt = uint64(block.timestamp);

        StorageLib.setVaultCampaign(vault, campaignId);

        emit CampaignVaultRegistered(campaignId, vault, lockProfile);
    }

    /**
     * @notice Updates strategy registry address
     * @dev Only callable by CAMPAIGN_ADMIN.
     *      Allows upgrading strategy registry contract.
     * @param newRegistry New strategy registry address
     */
    function setStrategyRegistry(address newRegistry) external onlyRole(aclManager.campaignAdminRole()) {
        if (newRegistry == address(0)) revert ZeroAddress();
        strategyRegistry = newRegistry;
    }

    /**
     * @notice Updates NGO registry address used for campaign submission authorization
     * @dev Only callable by CAMPAIGN_ADMIN.
     * @param newRegistry New NGO registry address
     */
    function setNGORegistry(address newRegistry) external onlyRole(aclManager.campaignAdminRole()) {
        if (newRegistry == address(0)) revert ZeroAddress();
        address previous = ngoRegistry;
        ngoRegistry = newRegistry;
        emit NGORegistryUpdated(previous, newRegistry);
    }

    /**
     * @notice Updates locked stake amount for a campaign
     * @dev Only callable by CAMPAIGN_ADMIN.
     *      Locked stake cannot be withdrawn by supporters.
     * @param campaignId Campaign identifier
     * @param lockedAmount New locked stake amount
     */
    function updateLockedStake(bytes32 campaignId, uint256 lockedAmount)
        external
        onlyRole(aclManager.campaignAdminRole())
    {
        GiveTypes.CampaignConfig storage cfg = _requireCampaign(campaignId);
        uint256 previous = cfg.lockedStake;
        cfg.lockedStake = lockedAmount;
        cfg.updatedAt = uint64(block.timestamp);

        emit LockedStakeUpdated(campaignId, previous, lockedAmount);
    }

    // ============================================
    // EXTERNAL FUNCTIONS - STAKE ESCROW
    // ============================================

    /**
     * @notice Records a stake deposit for a supporter
     * @dev Only callable by CAMPAIGN_CURATOR (vault contract).
     *      Tracks stake shares, timestamps for voting eligibility.
     *      Flash loan protection: Records stakeTimestamp for MIN_STAKE_DURATION check.
     *      Cannot stake to cancelled or completed campaigns.
     * @param campaignId Campaign identifier
     * @param supporter Address of supporter
     * @param amount Amount to stake
     */
    function recordStakeDeposit(bytes32 campaignId, address supporter, uint256 amount)
        external
        onlyRole(aclManager.campaignCuratorRole())
    {
        if (supporter == address(0)) revert ZeroAddress();
        if (amount == 0) revert InvalidStakeAmount();

        GiveTypes.CampaignConfig storage cfg = _requireCampaign(campaignId);
        if (
            cfg.status == GiveTypes.CampaignStatus.Cancelled || cfg.status == GiveTypes.CampaignStatus.Completed
                || cfg.status == GiveTypes.CampaignStatus.Unknown
        ) {
            revert InvalidCampaignStatus(campaignId, cfg.status);
        }

        GiveTypes.CampaignStakeState storage stakeState = StorageLib.campaignStake(campaignId);
        GiveTypes.SupporterStake storage stake = stakeState.supporterStake[supporter];

        if (!stake.exists) {
            stakeState.supporters.push(supporter);
            stake.exists = true;
            stake.lastUpdated = uint64(block.timestamp);
            // Flash loan protection: Record initial stake timestamp
            // Must be staked for MIN_STAKE_DURATION before voting eligibility
            stake.stakeTimestamp = uint64(block.timestamp);
        }

        stake.shares += amount;
        stake.lastUpdated = uint64(block.timestamp);
        stake.requestedExit = false;

        stakeState.totalActive += amount;
        cfg.totalStaked += amount;
        cfg.updatedAt = uint64(block.timestamp);

        emit StakeDeposited(campaignId, supporter, amount, cfg.totalStaked);
    }

    /**
     * @notice Requests a stake exit for a supporter
     * @dev Only callable by CAMPAIGN_CURATOR (vault contract).
     *      Moves stake from active to pending withdrawal.
     *      Cannot request exit from cancelled or completed campaigns.
     * @param campaignId Campaign identifier
     * @param supporter Address of supporter
     * @param amount Amount to exit
     */
    function requestStakeExit(bytes32 campaignId, address supporter, uint256 amount)
        external
        onlyRole(aclManager.campaignCuratorRole())
    {
        if (supporter == address(0)) revert ZeroAddress();
        if (amount == 0) revert InvalidStakeAmount();

        GiveTypes.CampaignConfig storage cfg = _requireCampaign(campaignId);
        if (cfg.status == GiveTypes.CampaignStatus.Cancelled || cfg.status == GiveTypes.CampaignStatus.Completed) {
            revert InvalidCampaignStatus(campaignId, cfg.status);
        }

        GiveTypes.CampaignStakeState storage stakeState = StorageLib.campaignStake(campaignId);
        GiveTypes.SupporterStake storage stake = stakeState.supporterStake[supporter];
        if (!stake.exists || stake.shares < amount) {
            revert SupporterStakeMissing(supporter);
        }

        stake.shares -= amount;
        stake.pendingWithdrawal += amount;
        stake.lastUpdated = uint64(block.timestamp);
        stake.requestedExit = true;

        stakeState.totalActive -= amount;
        stakeState.totalPendingExit += amount;

        emit StakeExitRequested(campaignId, supporter, amount);
    }

    /**
     * @notice Finalizes a stake exit for a supporter
     * @dev Only callable by CAMPAIGN_ADMIN.
     *      Moves stake from pending withdrawal to fully withdrawn.
     *      Updates total stake accounting.
     * @param campaignId Campaign identifier
     * @param supporter Address of supporter
     * @param amount Amount to finalize
     */
    function finalizeStakeExit(bytes32 campaignId, address supporter, uint256 amount)
        external
        onlyRole(aclManager.campaignAdminRole())
    {
        if (supporter == address(0)) revert ZeroAddress();
        if (amount == 0) revert InvalidStakeAmount();

        GiveTypes.CampaignConfig storage cfg = _requireCampaign(campaignId);
        GiveTypes.CampaignStakeState storage stakeState = StorageLib.campaignStake(campaignId);
        GiveTypes.SupporterStake storage stake = stakeState.supporterStake[supporter];
        if (!stake.exists || stake.pendingWithdrawal < amount) {
            revert SupporterStakeMissing(supporter);
        }

        stake.pendingWithdrawal -= amount;
        stake.lastUpdated = uint64(block.timestamp);
        if (stake.pendingWithdrawal == 0) {
            stake.requestedExit = false;
        }

        if (stake.shares == 0 && stake.pendingWithdrawal == 0) {
            stake.exists = false;
        }

        if (stakeState.totalPendingExit < amount) {
            stakeState.totalPendingExit = 0;
        } else {
            stakeState.totalPendingExit -= amount;
        }

        if (cfg.totalStaked < amount) {
            cfg.totalStaked = 0;
        } else {
            cfg.totalStaked -= amount;
        }

        cfg.updatedAt = uint64(block.timestamp);

        emit StakeExitFinalized(campaignId, supporter, amount, stake.shares);
    }

    // ============================================
    // EXTERNAL FUNCTIONS - CHECKPOINTS
    // ============================================

    /**
     * @notice Schedules a new checkpoint for a campaign
     * @dev Only callable by CAMPAIGN_ADMIN.
     *      Checkpoints are periodic governance votes for campaign oversight.
     *      Returns sequential index starting from 0.
     * @param campaignId Campaign identifier
     * @param input Checkpoint configuration
     * @return index Checkpoint index
     */
    function scheduleCheckpoint(bytes32 campaignId, CheckpointInput calldata input)
        external
        onlyRole(aclManager.campaignAdminRole())
        returns (uint256 index)
    {
        if (input.windowStart == 0 || input.windowEnd <= input.windowStart || input.executionDeadline < input.windowEnd)
        {
            revert InvalidCheckpointWindow();
        }
        if (input.quorumBps == 0 || input.quorumBps > 10_000) {
            revert InvalidCheckpointWindow();
        }

        GiveTypes.CampaignConfig storage cfg = _requireCampaign(campaignId);
        GiveTypes.CampaignCheckpointState storage cpState = StorageLib.campaignCheckpoints(campaignId);

        index = cpState.nextIndex;
        cpState.nextIndex += 1;

        GiveTypes.CampaignCheckpoint storage checkpoint = cpState.checkpoints[index];
        checkpoint.index = index;
        checkpoint.windowStart = input.windowStart;
        checkpoint.windowEnd = input.windowEnd;
        checkpoint.executionDeadline = input.executionDeadline;
        checkpoint.quorumBps = input.quorumBps;
        checkpoint.status = GiveTypes.CheckpointStatus.Scheduled;
        checkpoint.totalEligibleVotes = uint208(cfg.totalStaked);
        checkpoint.startBlock = uint32(block.number);
        checkpoint.votingStartsAt = input.windowStart;
        checkpoint.votingEndsAt = input.windowEnd;

        emit CheckpointScheduled(campaignId, index, input.windowStart, input.windowEnd, input.quorumBps);
    }

    /**
     * @notice Updates checkpoint status
     * @dev Only callable by CHECKPOINT_COUNCIL.
     *      Status transitions: Scheduled → Voting → Succeeded/Failed.
     *      Captures snapshot block when entering Voting status (flash loan protection).
     *      Halts payouts on Failed status.
     * @param campaignId Campaign identifier
     * @param index Checkpoint index
     * @param newStatus New checkpoint status
     */
    function updateCheckpointStatus(bytes32 campaignId, uint256 index, GiveTypes.CheckpointStatus newStatus)
        external
        onlyRole(aclManager.checkpointCouncilRole())
    {
        if (newStatus == GiveTypes.CheckpointStatus.None) {
            revert InvalidCheckpointStatus(newStatus);
        }

        GiveTypes.CampaignCheckpointState storage cpState = StorageLib.campaignCheckpoints(campaignId);
        GiveTypes.CampaignCheckpoint storage checkpoint = cpState.checkpoints[index];
        if (checkpoint.windowStart == 0) {
            revert CheckpointNotFound(campaignId, index);
        }

        GiveTypes.CheckpointStatus previous = checkpoint.status;
        if (previous == newStatus) return; // Idempotent

        checkpoint.status = newStatus;

        if (newStatus == GiveTypes.CheckpointStatus.Voting) {
            checkpoint.startBlock = uint32(block.number);
            // Flash loan protection: Capture snapshot block for voting power calculation
            // Voting power will be based on stakes at this block, not current balance
            checkpoint.snapshotBlock = uint32(block.number);
        }

        if (newStatus == GiveTypes.CheckpointStatus.Succeeded || newStatus == GiveTypes.CheckpointStatus.Failed) {
            checkpoint.endBlock = uint32(block.number);
        }

        emit CheckpointStatusUpdated(campaignId, index, previous, newStatus);

        if (newStatus == GiveTypes.CheckpointStatus.Failed) {
            GiveTypes.CampaignConfig storage cfg = _requireCampaign(campaignId);
            cfg.payoutsHalted = true;
            emit PayoutsHalted(campaignId, true);
        }
    }

    /**
     * @notice Casts a vote on a checkpoint
     * @dev Callable by any supporter with stake.
     *      Flash loan protection: Requires MIN_STAKE_DURATION elapsed since stake.
     *      One vote per supporter per checkpoint.
     *      Voting power equals stake shares.
     * @param campaignId Campaign identifier
     * @param index Checkpoint index
     * @param support True to vote in favor, false to vote against
     */
    function voteOnCheckpoint(bytes32 campaignId, uint256 index, bool support) external {
        GiveTypes.CampaignCheckpointState storage cpState = StorageLib.campaignCheckpoints(campaignId);
        GiveTypes.CampaignCheckpoint storage checkpoint = cpState.checkpoints[index];
        if (checkpoint.status != GiveTypes.CheckpointStatus.Voting) {
            revert InvalidCheckpointStatus(checkpoint.status);
        }
        if (block.timestamp < checkpoint.votingStartsAt || block.timestamp > checkpoint.votingEndsAt) {
            revert InvalidCheckpointWindow();
        }
        if (checkpoint.hasVoted[msg.sender]) revert AlreadyVoted(msg.sender);

        GiveTypes.CampaignStakeState storage stakeState = StorageLib.campaignStake(campaignId);
        GiveTypes.SupporterStake storage stake = stakeState.supporterStake[msg.sender];
        if (!stake.exists || stake.shares == 0) {
            revert NoVotingPower(msg.sender);
        }

        // Flash loan protection: Enforce minimum stake duration
        // Voter must have staked for at least MIN_STAKE_DURATION before voting eligibility
        if (block.timestamp < stake.stakeTimestamp + MIN_STAKE_DURATION) {
            revert NoVotingPower(msg.sender);
        }

        uint208 weight = uint208(stake.shares);
        checkpoint.hasVoted[msg.sender] = true;
        checkpoint.votedFor[msg.sender] = support;

        if (support) {
            checkpoint.votesFor += weight;
        } else {
            checkpoint.votesAgainst += weight;
        }

        emit CheckpointVoteCast(campaignId, index, msg.sender, support, weight);
    }

    /**
     * @notice Finalizes a checkpoint after voting ends
     * @dev Only callable by CAMPAIGN_ADMIN.
     *      Calculates quorum and determines Succeeded/Failed outcome.
     *      Halts payouts on failure, resumes on success.
     * @param campaignId Campaign identifier
     * @param index Checkpoint index
     */
    function finalizeCheckpoint(bytes32 campaignId, uint256 index) external onlyRole(aclManager.campaignAdminRole()) {
        GiveTypes.CampaignCheckpointState storage cpState = StorageLib.campaignCheckpoints(campaignId);
        GiveTypes.CampaignCheckpoint storage checkpoint = cpState.checkpoints[index];
        if (checkpoint.status != GiveTypes.CheckpointStatus.Voting) {
            revert InvalidCheckpointStatus(checkpoint.status);
        }
        if (block.timestamp <= checkpoint.votingEndsAt) {
            revert InvalidCheckpointWindow();
        }

        uint208 totalVotesCast = checkpoint.votesFor + checkpoint.votesAgainst;
        if (checkpoint.totalEligibleVotes == 0) {
            GiveTypes.CampaignStakeState storage stakeState = StorageLib.campaignStake(campaignId);
            checkpoint.totalEligibleVotes = uint208(stakeState.totalActive);
        }

        bool quorumMet = checkpoint.totalEligibleVotes == 0
            ? true
            : totalVotesCast >= (uint208(checkpoint.quorumBps) * checkpoint.totalEligibleVotes) / 10_000;

        GiveTypes.CheckpointStatus result = quorumMet && checkpoint.votesFor > checkpoint.votesAgainst
            ? GiveTypes.CheckpointStatus.Succeeded
            : GiveTypes.CheckpointStatus.Failed;

        checkpoint.status = result;
        checkpoint.endBlock = uint32(block.number);

        emit CheckpointStatusUpdated(campaignId, index, GiveTypes.CheckpointStatus.Voting, result);

        GiveTypes.CampaignConfig storage cfg = _requireCampaign(campaignId);
        if (result == GiveTypes.CheckpointStatus.Failed) {
            cfg.payoutsHalted = true;
            cfg.status = GiveTypes.CampaignStatus.Paused;
            emit PayoutsHalted(campaignId, true);
        } else {
            if (cfg.payoutsHalted) {
                cfg.payoutsHalted = false;
                emit PayoutsHalted(campaignId, false);
            }
        }
    }

    // ============================================
    // EXTERNAL VIEW FUNCTIONS
    // ============================================

    /**
     * @notice Retrieves a campaign's configuration
     * @dev Reverts if campaign does not exist
     * @param campaignId Campaign identifier
     * @return Campaign configuration struct
     */
    function getCampaign(bytes32 campaignId) external view returns (GiveTypes.CampaignConfig memory) {
        GiveTypes.CampaignConfig storage cfg = StorageLib.campaign(campaignId);
        if (!cfg.exists) revert CampaignNotFound(campaignId);
        return cfg;
    }

    /**
     * @notice Retrieves campaign configuration by vault address
     * @dev Useful for vault contracts to look up their campaign
     * @param vault Vault address
     * @return Campaign configuration struct
     */
    function getCampaignByVault(address vault) external view returns (GiveTypes.CampaignConfig memory) {
        bytes32 campaignId = StorageLib.getVaultCampaign(vault);
        if (campaignId == bytes32(0)) revert CampaignNotFound(bytes32(0));
        return StorageLib.campaign(campaignId);
    }

    /**
     * @notice Returns all registered campaign IDs
     * @dev Useful for UI enumeration and discovery.
     *      Order is insertion order (not sorted).
     * @return Array of campaign identifiers
     */
    function listCampaignIds() external view returns (bytes32[] memory) {
        return _campaignIds;
    }

    /**
     * @notice Retrieves a supporter's stake position
     * @dev Returns stake shares, pending withdrawal, and timestamps
     * @param campaignId Campaign identifier
     * @param supporter Address of supporter
     * @return Supporter stake struct
     */
    function getStakePosition(bytes32 campaignId, address supporter)
        external
        view
        returns (GiveTypes.SupporterStake memory)
    {
        GiveTypes.CampaignStakeState storage stakeState = StorageLib.campaignStake(campaignId);
        return stakeState.supporterStake[supporter];
    }

    /**
     * @notice Retrieves checkpoint details
     * @dev Returns voting window, quorum, status, and eligible stake
     * @param campaignId Campaign identifier
     * @param index Checkpoint index
     * @return windowStart Voting window start timestamp
     * @return windowEnd Voting window end timestamp
     * @return executionDeadline Execution deadline
     * @return quorumBps Quorum requirement in basis points
     * @return status Checkpoint status
     * @return totalEligibleStake Total eligible stake for voting
     */
    function getCheckpoint(bytes32 campaignId, uint256 index)
        external
        view
        returns (
            uint64 windowStart,
            uint64 windowEnd,
            uint64 executionDeadline,
            uint16 quorumBps,
            GiveTypes.CheckpointStatus status,
            uint256 totalEligibleStake
        )
    {
        GiveTypes.CampaignCheckpointState storage cpState = StorageLib.campaignCheckpoints(campaignId);
        GiveTypes.CampaignCheckpoint storage checkpoint = cpState.checkpoints[index];
        if (checkpoint.windowStart == 0) {
            revert CheckpointNotFound(campaignId, index);
        }

        return (
            checkpoint.windowStart,
            checkpoint.windowEnd,
            checkpoint.executionDeadline,
            checkpoint.quorumBps,
            checkpoint.status,
            uint256(checkpoint.totalEligibleVotes)
        );
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
     * @notice Validates campaign input parameters
     * @dev Checks for zero values, consistency, and valid ranges
     * @param input Campaign input struct
     */
    function _validateCampaignInput(CampaignInput calldata input) private pure {
        if (
            input.id == bytes32(0) || input.payoutRecipient == address(0) || input.strategyId == bytes32(0)
                || input.targetStake == 0 || input.minStake > input.targetStake
        ) {
            revert InvalidCampaignConfig(input.id);
        }
        if (input.fundraisingEnd != 0 && input.fundraisingEnd <= input.fundraisingStart) {
            revert InvalidCampaignConfig(input.id);
        }
    }

    /**
     * @notice Requires campaign to exist and returns storage reference
     * @dev Reverts if campaign not found
     * @param campaignId Campaign identifier
     * @return cfg Campaign configuration storage reference
     */
    function _requireCampaign(bytes32 campaignId) private view returns (GiveTypes.CampaignConfig storage cfg) {
        cfg = StorageLib.campaign(campaignId);
        if (!cfg.exists) revert CampaignNotFound(campaignId);
    }

    /**
     * @notice Fetches and validates strategy from StrategyRegistry
     * @dev Ensures strategy exists and is not Deprecated.
     *      FadingOut strategies are allowed (product decision).
     * @param strategyId Strategy identifier
     * @param campaignId Campaign identifier (for error context)
     * @return strategyCfg Strategy configuration
     */
    function _fetchStrategy(bytes32 strategyId, bytes32 campaignId)
        private
        view
        returns (GiveTypes.StrategyConfig memory strategyCfg)
    {
        address registry = strategyRegistry;
        if (registry == address(0)) revert StrategyRegistryNotConfigured();

        try IStrategyRegistry(registry).getStrategy(strategyId) returns (GiveTypes.StrategyConfig memory cfg) {
            if (!cfg.exists || cfg.status == GiveTypes.StrategyStatus.Deprecated) {
                revert InvalidCampaignConfig(campaignId);
            }
            strategyCfg = cfg;
        } catch {
            revert InvalidCampaignConfig(campaignId);
        }
    }

    /**
     * @notice Validates submitter authorization for NGO payout recipient
     * @dev Requires configured NGO registry, approved NGO, and submitter authorization.
     * @param payoutRecipient NGO payout recipient address
     * @param submitter Campaign submitter
     */
    function _validateSubmissionAuthorization(address payoutRecipient, address submitter) private view {
        address registry = ngoRegistry;
        if (registry == address(0)) revert NGORegistryNotConfigured();

        if (!INGORegistry(registry).isApproved(payoutRecipient)) {
            revert NGONotApproved(payoutRecipient);
        }

        if (!INGORegistry(registry).canSubmitCampaignFor(payoutRecipient, submitter)) {
            revert UnauthorizedCampaignSubmitter(payoutRecipient, submitter);
        }
    }
}
