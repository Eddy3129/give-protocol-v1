// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title GiveTypes
 * @author GIVE Labs
 * @notice Canonical data definitions shared across the GIVE Protocol architecture
 * @dev This library contains all struct and enum definitions used throughout the protocol.
 *      Structs without mappings include storage gaps for future upgradability.
 *      Structs with mappings cannot have gaps due to Solidity restrictions and must
 *      append new fields carefully to maintain backward compatibility.
 */
library GiveTypes {
    // ============================================
    // ENUMS
    // ============================================

    /**
     * @notice Enumerates adapter behaviors for yield generation strategies
     * @dev Used by modules to apply the correct accounting logic for each adapter type
     */
    enum AdapterKind {
        Unknown, // Default/uninitialized state
        CompoundingValue, // Balance constant, exchange rate accrues (e.g., sUSDe, wstETH, Compound cTokens)
        ClaimableYield, // Yield must be claimed and realised during harvest (e.g., liquidity mining rewards)
        BalanceGrowth, // Balance increases automatically over time (e.g., Aave aTokens)
        FixedMaturityToken // Principal/yield tokens with maturity or expiry (e.g., Pendle PT)
    }

    /**
     * @notice Lifecycle states for yield strategies
     * @dev Used to manage strategy deprecation gracefully
     */
    enum StrategyStatus {
        Unknown, // Default/uninitialized state
        Active, // Strategy is active and can be selected by new campaigns
        FadingOut, // Strategy is being deprecated but existing campaigns can continue
        Deprecated // Strategy is fully deprecated and cannot be selected
    }

    /**
     * @notice Lifecycle states for campaign management
     * @dev Campaigns progress through these states from submission to completion
     */
    enum CampaignStatus {
        Unknown, // Default/uninitialized state
        Submitted, // Campaign submitted by proposer, awaiting admin approval
        Approved, // Campaign approved by admin, vault not yet deployed
        Rejected, // Campaign rejected by admin, deposit slashed
        Active, // Campaign is active with deployed vault accepting deposits
        Paused, // Campaign temporarily paused (e.g., failed checkpoint)
        Completed, // Campaign successfully completed
        Cancelled // Campaign cancelled by admin
    }

    /**
     * @notice States for campaign checkpoint voting
     * @dev Checkpoints allow supporters to vote on campaign progress milestones
     */
    enum CheckpointStatus {
        None, // Default/uninitialized state
        Scheduled, // Checkpoint scheduled but voting not yet started
        Voting, // Voting is currently active
        Succeeded, // Checkpoint passed (quorum met, votesFor > votesAgainst)
        Failed, // Checkpoint failed (quorum not met or votesAgainst >= votesFor)
        Executed, // Checkpoint result executed
        Canceled // Checkpoint cancelled before execution
    }

    // ============================================
    // SYSTEM & PROTOCOL CONFIGURATION
    // ============================================

    /**
     * @notice Global protocol configuration and wiring
     * @dev Stores core protocol addresses and initialization state
     */
    struct SystemConfig {
        address aclManager; // ACL manager for role-based access control
        address upgrader; // Address authorized to perform UUPS upgrades
        address bootstrapper; // Address that performed initial deployment
        uint64 version; // Protocol version number
        uint64 lastBootstrapAt; // Timestamp of last bootstrap
        bool initialized; // Whether system has been initialized
        uint256[50] __gap; // Storage gap for future upgrades
    }

    // ============================================
    // VAULT CONFIGURATION
    // ============================================

    /**
     * @notice Vault-level configuration parameters
     * @dev Contains all operational parameters for a vault instance
     */
    struct VaultConfig {
        bytes32 id; // Unique vault identifier
        address proxy; // Vault proxy address
        address implementation; // Vault implementation address
        address asset; // Underlying ERC20 asset (e.g., WETH)
        bytes32 adapterId; // Identifier for yield adapter
        bytes32 donationModuleId; // Identifier for donation module
        bytes32 riskId; // Identifier for risk parameters
        address activeAdapter; // Currently active yield adapter
        address donationRouter; // Donation routing contract
        address wrappedNative; // Wrapped native token address (e.g., WETH)
        uint16 cashBufferBps; // Cash buffer in basis points (e.g., 100 = 1%)
        uint16 slippageBps; // Maximum slippage tolerance in basis points
        uint16 maxLossBps; // Maximum acceptable loss in basis points
        uint256 lastHarvestTime; // Timestamp of last yield harvest
        uint256 totalProfit; // Cumulative profit generated
        uint256 totalLoss; // Cumulative losses incurred
        uint256 maxVaultDeposit; // Maximum total deposits allowed
        uint256 maxVaultBorrow; // Maximum borrowing capacity
        bool emergencyShutdown; // Emergency shutdown flag
        uint64 emergencyActivatedAt; // Timestamp when emergency was activated
        bool investPaused; // Whether new investments are paused
        bool harvestPaused; // Whether yield harvesting is paused
        bool active; // Whether vault is active
        uint256[50] __gap; // Storage gap for future upgrades
    }

    /**
     * @notice Campaign-specific vault metadata
     * @dev Links vault to its campaign and strategy
     */
    struct CampaignVaultMeta {
        bytes32 id; // Unique metadata identifier
        bytes32 campaignId; // Associated campaign identifier
        bytes32 strategyId; // Associated strategy identifier
        bytes32 lockProfile; // Lock profile (flexible/locked/progressive)
        address factory; // Factory that deployed this vault
        bool exists; // Whether this metadata exists
        uint256[50] __gap; // Storage gap for future upgrades
    }

    // ============================================
    // ASSET CONFIGURATION
    // ============================================

    /**
     * @notice Configuration for supported assets
     * @dev Stores metadata about assets that can be used in the protocol
     */
    struct AssetConfig {
        bytes32 id; // Unique asset identifier
        address token; // Token contract address
        uint8 decimals; // Token decimals (cached for gas efficiency)
        bytes32 riskTier; // Risk tier classification
        address oracle; // Price oracle address
        bool enabled; // Whether asset is enabled for use
        uint256[50] __gap; // Storage gap for future upgrades
    }

    // ============================================
    // ADAPTER CONFIGURATION
    // ============================================

    /**
     * @notice Yield adapter configuration
     * @dev Stores wiring and behavior flags for yield adapters
     */
    struct AdapterConfig {
        bytes32 id; // Unique adapter identifier
        address proxy; // Adapter proxy address (if upgradeable)
        address implementation; // Adapter implementation address
        address asset; // Asset this adapter works with
        address vault; // Vault this adapter belongs to
        AdapterKind kind; // Adapter behavior classification
        bytes32 vaultId; // Associated vault identifier
        bytes32 metadataHash; // IPFS hash for additional metadata
        bool active; // Whether adapter is active
        uint256[50] __gap; // Storage gap for future upgrades
    }

    // ============================================
    // SYNTHETIC ASSETS (Optional Feature)
    // ============================================

    /**
     * @notice Synthetic asset state
     * @dev Represents a synthetic asset within the protocol
     * @custom:security Cannot include storage gap due to mapping field
     */
    struct SyntheticAsset {
        bytes32 id; // Unique synthetic asset identifier
        address proxy; // Synthetic asset proxy address
        address asset; // Underlying asset
        uint256 totalSupply; // Total supply of synthetic asset
        bool active; // Whether synthetic asset is active
        mapping(address => uint256) balances; // User balances
    }

    // ============================================
    // RISK MANAGEMENT
    // ============================================

    /**
     * @notice Risk parameters for vaults or asset groupings
     * @dev Versioned risk configuration supporting protocol risk management
     */
    struct RiskConfig {
        bytes32 id; // Unique risk configuration identifier
        uint64 createdAt; // Creation timestamp
        uint64 updatedAt; // Last update timestamp
        uint16 ltvBps; // Loan-to-value ratio in basis points
        uint16 liquidationThresholdBps; // Liquidation threshold in basis points
        uint16 liquidationPenaltyBps; // Liquidation penalty in basis points
        uint16 borrowCapBps; // Borrowing cap in basis points
        uint16 depositCapBps; // Deposit cap in basis points
        bytes32 dataHash; // Hash of additional encoded risk parameters
        uint64 version; // Risk configuration version
        uint256 maxDeposit; // Maximum deposit amount
        uint256 maxBorrow; // Maximum borrow amount
        bool exists; // Whether configuration exists
        bool active; // Whether configuration is active
        uint256[50] __gap; // Storage gap for future upgrades
    }

    // ============================================
    // POSITION TRACKING
    // ============================================

    /**
     * @notice User position state
     * @dev Tracks user position for enumerability and analytics
     */
    struct PositionState {
        bytes32 id; // Unique position identifier
        address owner; // Position owner address
        bytes32 vaultId; // Associated vault identifier
        uint256 principal; // Principal amount deposited
        uint256 shares; // Vault shares owned
        uint256 normalizedDebtIndex; // Normalized debt index for interest calculation
        uint256 lastAccrued; // Timestamp of last interest accrual
        uint256[50] __gap; // Storage gap for future upgrades
    }

    // ============================================
    // CROSS-MODULE COMMUNICATION
    // ============================================

    /**
     * @notice Standard callback payload for cross-communication
     * @dev Used when adapters/modules need to communicate with each other
     */
    struct CallbackPayload {
        bytes32 sourceId; // Identifier of source module
        bytes32 targetId; // Identifier of target module
        bytes data; // Encoded callback data
    }

    // ============================================
    // ACCESS CONTROL
    // ============================================

    /**
     * @notice Role metadata managed by ACL Manager
     * @dev Tracks role assignments and member enumeration
     * @custom:security Cannot include storage gap due to mapping fields
     */
    struct RoleAssignments {
        bytes32 roleId; // Unique role identifier
        address admin; // Current role admin
        address pendingAdmin; // Pending admin (two-step transfer)
        bool exists; // Whether role exists
        uint64 createdAt; // Role creation timestamp
        uint64 updatedAt; // Last update timestamp
        address[] memberList; // Enumerable list of role members
        mapping(address => bool) isMember; // Quick membership check
        mapping(address => uint256) memberIndex; // Index in memberList (1-indexed for swap-and-pop)
    }

    // ============================================
    // USER PREFERENCES & PAYOUT ROUTING
    // ============================================

    /**
     * @notice Legacy user donation preference (being replaced by PayoutRouter)
     * @dev Stores user preferences for NGO donations in old DonationRouter
     */
    struct UserPreference {
        address selectedNGO; // Selected NGO address
        uint8 allocationPercentage; // Percentage allocated to NGO (0-100)
        uint256 lastUpdated; // Last update timestamp
        uint256[50] __gap; // Storage gap for future upgrades
    }

    /**
     * @notice Campaign-specific user preference
     * @dev Stores user allocation preferences for campaign yield distribution
     */
    struct CampaignPreference {
        bytes32 campaignId; // Campaign identifier
        address beneficiary; // Beneficiary address for personal yield portion
        uint8 allocationPercentage; // Percentage to campaign (0-100, remainder to beneficiary)
        uint256 lastUpdated; // Last update timestamp
        uint256[50] __gap; // Storage gap for future upgrades
    }

    /**
     * @notice Legacy donation router state
     * @dev State for old DonationRouter (being replaced by PayoutRouter)
     * @custom:security Cannot include storage gap due to mapping fields
     */
    struct DonationRouterState {
        address registry; // NGO registry address
        address feeRecipient; // Fee recipient address
        address protocolTreasury; // Protocol treasury address
        uint256 feeBps; // Protocol fee in basis points
        uint256 totalDistributions; // Total distributions made
        uint256 totalNGOsSupported; // Total unique NGOs supported
        mapping(address => UserPreference) userPreferences; // User preferences
        mapping(address => mapping(address => uint256)) userAssetShares; // User shares per asset
        mapping(address => uint256) totalAssetShares; // Total shares per asset
        mapping(address => address[]) usersWithShares; // Users with shares in each asset
        mapping(address => mapping(address => bool)) hasShares; // Quick lookup for shares
        mapping(address => uint256) totalDonated; // Total donated per asset
        mapping(address => uint256) totalFeeCollected; // Total fees per asset
        mapping(address => uint256) totalProtocolFees; // Total protocol fees per asset
        mapping(address => bool) authorizedCallers; // Authorized caller whitelist
        uint8[3] validAllocations; // Valid allocation percentages
    }

    /**
     * @notice Payout router state for campaign-based distribution
     * @dev Replaces DonationRouter with campaign-centric model
     * @custom:security Cannot include storage gap due to mapping fields
     */
    struct PayoutRouterState {
        address campaignRegistry; // Campaign registry address
        address feeRecipient; // Fee recipient address
        address protocolTreasury; // Protocol treasury address
        uint256 feeBps; // Protocol fee in basis points
        uint256 totalDistributions; // Total distributions made
        mapping(address => bool) authorizedCallers; // Authorized caller whitelist
        mapping(address => mapping(address => uint256)) userVaultShares; // User shares per vault
        mapping(address => uint256) totalVaultShares; // Total shares per vault
        mapping(address => address[]) vaultShareholders; // Shareholders per vault
        mapping(address => mapping(address => bool)) hasVaultShare; // Quick share lookup
        mapping(address => mapping(address => CampaignPreference)) userPreferences; // User preferences per vault
        mapping(bytes32 => uint256) campaignProtocolFees; // Protocol fees per campaign
        mapping(bytes32 => uint256) campaignTotalPayouts; // Total payouts per campaign
        mapping(address => bytes32) vaultCampaigns; // Vault to campaign mapping
        uint8[3] validAllocations; // Valid allocation percentages (e.g., [25, 50, 75])
        mapping(uint256 => PendingFeeChange) pendingFeeChanges; // Pending fee changes (timelock)
        uint256 feeChangeNonce; // Nonce for fee change tracking

        // Pull-model reward accounting (Phase 1.6)
        mapping(address => mapping(address => uint256)) accumulatedYieldPerShare; // Vault => asset => acc yield/share (1e18)
        mapping(address => mapping(address => mapping(address => uint256))) userYieldDebt; // Vault => asset => user => acc snapshot
        mapping(address => mapping(address => mapping(address => uint256))) pendingYield; // Vault => asset => user => claimable
        mapping(address => address[]) vaultAssets; // Assets used by each vault for reward accrual sync
        mapping(address => mapping(address => bool)) hasVaultAsset; // Quick lookup for vault asset registration
    }

    /**
     * @notice Pending fee change with timelock protection
     * @dev Prevents sudden fee increases by requiring time delay
     */
    struct PendingFeeChange {
        uint256 newFeeBps; // Proposed new fee in basis points
        address newRecipient; // Proposed new fee recipient
        uint256 effectiveTimestamp; // When change becomes effective
        bool exists; // Whether pending change exists
        uint256[50] __gap; // Storage gap for future upgrades
    }

    // ============================================
    // NGO REGISTRY
    // ============================================

    /**
     * @notice NGO information and verification data
     * @dev Stores metadata and KYC information for registered NGOs
     */
    struct NGOInfo {
        string metadataCid; // IPFS CID for NGO metadata
        bytes32 kycHash; // Hash of KYC verification data
        address attestor; // Address that attested to NGO legitimacy
        uint256 createdAt; // Registration timestamp
        uint256 updatedAt; // Last update timestamp
        uint256 version; // Version number for updates
        uint256 totalReceived; // Total donations received
        bool isActive; // Whether NGO is active
        uint256[50] __gap; // Storage gap for future upgrades
    }

    /**
     * @notice NGO registry state
     * @dev Manages approved NGOs and their metadata
     * @custom:security Cannot include storage gap due to mapping fields
     */
    struct NGORegistryState {
        mapping(address => bool) isApproved; // Quick approval check
        mapping(address => NGOInfo) ngoInfo; // NGO information
        address[] approvedNGOs; // Enumerable list of approved NGOs
        mapping(address => mapping(address => bool)) campaignSubmitters; // NGO => delegate => allowed
        mapping(address => mapping(address => bool)) pendingSubmitterAllowed; // NGO => delegate => pending allowed flag
        mapping(address => mapping(address => uint256)) pendingSubmitterEta; // NGO => delegate => ETA
        mapping(address => mapping(address => bool)) hasPendingSubmitterChange; // NGO => delegate => pending exists
        address currentNGO; // Current default NGO (if any)
        address pendingCurrentNGO; // Pending default NGO (timelock)
        uint256 currentNGOChangeETA; // Timelock expiry for default NGO change
    }

    // ============================================
    // STRATEGY MANAGEMENT
    // ============================================

    /**
     * @notice Yield strategy configuration
     * @dev Defines a reusable yield generation strategy
     */
    struct StrategyConfig {
        bytes32 id; // Unique strategy identifier
        address adapter; // Yield adapter contract address
        address creator; // Address that created the strategy
        bytes32 metadataHash; // IPFS hash for strategy metadata
        bytes32 riskTier; // Risk tier classification
        uint256 maxTvl; // Maximum total value locked allowed
        uint64 createdAt; // Creation timestamp
        uint64 updatedAt; // Last update timestamp
        StrategyStatus status; // Current lifecycle status
        bool exists; // Whether strategy exists
        uint256[50] __gap; // Storage gap for future upgrades
    }

    // ============================================
    // CAMPAIGN MANAGEMENT
    // ============================================

    /**
     * @notice Campaign configuration and state
     * @dev Contains all data for a campaign instance
     */
    struct CampaignConfig {
        bytes32 id; // Unique campaign identifier
        address proposer; // Address that proposed the campaign
        address curator; // Assigned campaign curator
        address payoutRecipient; // Address to receive campaign yield
        address vault; // Deployed campaign vault address
        bytes32 strategyId; // Selected yield strategy
        bytes32 metadataHash; // IPFS hash for campaign metadata
        uint256 targetStake; // Fundraising goal (target amount)
        uint256 minStake; // Minimum stake to activate campaign
        uint256 totalStaked; // Current total staked amount
        uint256 lockedStake; // Amount currently locked
        uint256 initialDeposit; // Anti-spam deposit (0.005 ETH)
        uint64 fundraisingStart; // Fundraising window start
        uint64 fundraisingEnd; // Fundraising window end
        uint64 createdAt; // Campaign creation timestamp
        uint64 updatedAt; // Last update timestamp
        CampaignStatus status; // Current lifecycle status
        bytes32 lockProfile; // Lock profile identifier (flexible/locked/progressive)
        uint16 checkpointQuorumBps; // Checkpoint quorum requirement in basis points
        uint64 checkpointVotingDelay; // Delay before checkpoint voting starts
        uint64 checkpointVotingPeriod; // Duration of checkpoint voting period
        bool exists; // Whether campaign exists
        bool payoutsHalted; // Whether payouts are halted (e.g., failed checkpoint)
        uint256[49] __gap; // Storage gap for future upgrades (49 slots after initialDeposit)
    }

    /**
     * @notice Supporter stake information
     * @dev Tracks individual supporter's stake in a campaign
     */
    struct SupporterStake {
        uint256 shares; // Vault shares owned
        uint256 escrow; // Amount in escrow (if applicable)
        uint256 pendingWithdrawal; // Amount pending withdrawal
        uint64 lockedUntil; // Lock expiry timestamp
        uint64 lastUpdated; // Last update timestamp
        bool requestedExit; // Whether exit has been requested
        bool exists; // Whether stake exists
        uint64 stakeTimestamp; // Timestamp when stake was first deposited (flash loan protection)
        uint256[49] __gap; // Storage gap for future upgrades
    }

    /**
     * @notice Campaign stake aggregation
     * @dev Aggregates all supporter stakes for a campaign
     * @custom:security Cannot include storage gap due to mapping field
     */
    struct CampaignStakeState {
        uint256 totalActive; // Total active stake
        uint256 totalPendingExit; // Total stake pending exit
        address[] supporters; // Enumerable list of supporters
        mapping(address => SupporterStake) supporterStake; // Supporter stake details
    }

    // ============================================
    // CHECKPOINT VOTING
    // ============================================

    /**
     * @notice Campaign checkpoint for milestone verification
     * @dev Allows supporters to vote on campaign progress
     * @custom:security Cannot include storage gap due to mapping fields
     */
    struct CampaignCheckpoint {
        uint256 index; // Checkpoint index number
        uint64 windowStart; // Voting window start
        uint64 windowEnd; // Voting window end
        uint64 executionDeadline; // Deadline for execution
        uint16 quorumBps; // Quorum requirement in basis points
        CheckpointStatus status; // Current checkpoint status
        uint32 startBlock; // Block when voting started
        uint32 endBlock; // Block when voting ended
        uint64 votingStartsAt; // Timestamp when voting starts
        uint64 votingEndsAt; // Timestamp when voting ends
        uint208 votesFor; // Total votes in favor
        uint208 votesAgainst; // Total votes against
        uint208 totalEligibleVotes; // Total eligible voting power
        bool executed; // Whether checkpoint has been executed
        uint32 snapshotBlock; // Snapshot block for voting power calculation (flash loan protection)
        mapping(address => bool) hasVoted; // Whether address has voted
        mapping(address => bool) votedFor; // Whether vote was in favor
    }

    /**
     * @notice Checkpoint state for a campaign
     * @dev Manages all checkpoints for a single campaign
     * @custom:security Cannot include storage gap due to mapping field
     */
    struct CampaignCheckpointState {
        uint256 nextIndex; // Next checkpoint index
        mapping(uint256 => CampaignCheckpoint) checkpoints; // Checkpoint details by index
    }
}
