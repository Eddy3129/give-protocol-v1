// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";

import {PayoutRouter} from "../../../src/payout/PayoutRouter.sol";
import {MockERC20} from "../../../src/mocks/MockERC20.sol";
import {GiveTypes} from "../../../src/types/GiveTypes.sol";

// ─── Minimal mocks ───────────────────────────────────────────────────────────

contract PRMockACL {
    function hasRole(bytes32, address) external pure returns (bool) {
        return false; // Force PayoutRouter to use local AccessControl roles
    }
}

contract PRMockCampaignRegistry {
    address public immutable payoutRecipient;
    bool public payoutsHalted;

    constructor(address recipient_) {
        payoutRecipient = recipient_;
    }

    function setPayoutsHalted(bool halted) external {
        payoutsHalted = halted;
    }

    function getCampaign(bytes32 id) external view returns (GiveTypes.CampaignConfig memory cfg) {
        uint256[49] memory gap;
        cfg.id = id;
        cfg.payoutRecipient = payoutRecipient;
        cfg.status = GiveTypes.CampaignStatus.Active;
        cfg.exists = true;
        cfg.payoutsHalted = payoutsHalted;
        cfg.__gap = gap;
    }
}

// ─── Handler ─────────────────────────────────────────────────────────────────

/// @title PayoutRouterHandler
/// @notice Invariant handler. This contract acts as the authorized vault.
///         Foundry fuzzer calls handler functions randomly; ghost variables
///         track cumulative state for invariant verification.
contract PayoutRouterHandler is Test {
    // ── Contracts under test ─────────────────────────────────────────
    PayoutRouter public immutable router;
    MockERC20 public immutable asset;
    PRMockCampaignRegistry public immutable registry;

    // ── Constants ────────────────────────────────────────────────────
    bytes32 public constant CAMPAIGN_ID = keccak256("invariant_campaign");
    uint256 public constant MAX_FEE_BPS = 1_000;
    uint256 public constant FEE_BPS = 250; // 2.5%

    // ── Actors ───────────────────────────────────────────────────────
    address[3] internal _actors;
    address internal immutable _admin;
    address internal immutable _campaignRecipient;

    // ── Ghost variables ──────────────────────────────────────────────
    /// @notice Sum of all amounts passed to recordYield
    uint256 public ghost_totalRecorded;
    /// @notice Sum of all amounts returned by claimYield
    uint256 public ghost_totalClaimed;
    /// @notice Set to true if pending yield ever decreases for an actor
    ///         with non-zero constant shares between recordYield calls
    bool public ghost_accumulatorDecreased;

    // ── Internal tracking ────────────────────────────────────────────
    /// @dev Pending snapshots taken just before each updateShares call,
    ///      used to verify monotonicity after the call returns
    uint256[3] internal _pendingSnapshot;

    constructor() {
        _admin = makeAddr("pr_admin");
        _campaignRecipient = makeAddr("pr_campaign_recipient");
        _actors[0] = makeAddr("pr_actor0");
        _actors[1] = makeAddr("pr_actor1");
        _actors[2] = makeAddr("pr_actor2");

        asset = new MockERC20("USDC", "USDC", 6);
        PRMockACL acl = new PRMockACL();
        registry = new PRMockCampaignRegistry(_campaignRecipient);

        router = new PayoutRouter();

        vm.startPrank(_admin);
        router.initialize(
            _admin, address(acl), address(registry), _admin, _admin, FEE_BPS
        );
        router.grantRole(router.VAULT_MANAGER_ROLE(), _admin);
        router.grantRole(router.FEE_MANAGER_ROLE(), _admin);
        // Register this handler contract as the authorized vault
        router.registerCampaignVault(address(this), CAMPAIGN_ID);
        router.setAuthorizedCaller(address(this), true);
        vm.stopPrank();
    }

    // ── Handler actions ──────────────────────────────────────────────

    /// @notice Simulates a vault updating a user's share count (deposit or withdraw).
    function updateShares(uint8 actorSeed, uint256 newShares) external {
        address actor = _actors[actorSeed % 3];
        newShares = bound(newShares, 0, 1_000_000e6);

        // Snapshot pending yield for all actors before share change
        _snapshotPending();

        router.updateUserShares(actor, newShares);

        // After updateUserShares, pending yield must not have decreased for any actor
        // (the internal _accruePending crystallises debt before changing shares)
        _checkMonotonicAfterUpdate();
    }

    /// @notice Simulates a vault harvesting yield and depositing it to the router.
    function recordYield(uint256 amount) external {
        if (router.getTotalVaultShares(address(this)) == 0) return;

        amount = bound(amount, 1e6, 10_000_000e6);

        // Mint tokens to this handler then forward to router (simulates harvest transfer)
        asset.mint(address(this), amount);
        asset.transfer(address(router), amount);

        // Snapshot pending before recording
        _snapshotPending();

        router.recordYield(address(asset), amount);
        ghost_totalRecorded += amount;

        // After recordYield, every actor with shares must have pending >= snapshot
        _checkMonotonicAfterRecord();
    }

    /// @notice Actor claims their accumulated yield.
    function claimYield(uint8 actorSeed) external {
        address actor = _actors[actorSeed % 3];
        vm.prank(actor);
        uint256 claimed = router.claimYield(address(this), address(asset));
        ghost_totalClaimed += claimed;
    }

    /// @notice Actor sets their yield split preference.
    function setPreference(uint8 actorSeed, uint8 allocSeed, bool useBeneficiary) external {
        address actor = _actors[actorSeed % 3];
        uint8[3] memory validAllocs = [uint8(50), uint8(75), uint8(100)];
        uint8 allocation = validAllocs[allocSeed % 3];
        address beneficiary = useBeneficiary ? _actors[(actorSeed + 1) % 3] : address(0);
        if (allocation < 100 && beneficiary == address(0)) {
            beneficiary = _actors[0]; // always supply a valid beneficiary when needed
        }
        vm.prank(actor);
        try router.setVaultPreference(address(this), beneficiary, allocation) {} catch {}
    }

    /// @notice Warp forward to simulate time passing (affects fee timelocks).
    function advanceTime(uint256 seconds_) external {
        skip(bound(seconds_, 1, 30 days));
    }

    // ── Getters ──────────────────────────────────────────────────────

    function actor(uint8 idx) external view returns (address) {
        return _actors[idx % 3];
    }

    /// @notice Router's current balance of the test asset.
    function routerBalance() external view returns (uint256) {
        return asset.balanceOf(address(router));
    }

    // ── Internal helpers ─────────────────────────────────────────────

    function _snapshotPending() internal {
        for (uint256 i = 0; i < 3; i++) {
            _pendingSnapshot[i] =
                router.getPendingYield(_actors[i], address(this), address(asset));
        }
    }

    function _checkMonotonicAfterUpdate() internal {
        for (uint256 i = 0; i < 3; i++) {
            uint256 after_ =
                router.getPendingYield(_actors[i], address(this), address(asset));
            // Pending must not decrease: updateUserShares accrues before changing shares
            if (after_ < _pendingSnapshot[i]) {
                ghost_accumulatorDecreased = true;
            }
        }
    }

    function _checkMonotonicAfterRecord() internal {
        for (uint256 i = 0; i < 3; i++) {
            uint256 shares = router.getUserVaultShares(_actors[i], address(this));
            uint256 after_ =
                router.getPendingYield(_actors[i], address(this), address(asset));
            // Only actors with shares should see pending increase
            if (shares > 0 && after_ < _pendingSnapshot[i]) {
                ghost_accumulatorDecreased = true;
            }
        }
    }
}
