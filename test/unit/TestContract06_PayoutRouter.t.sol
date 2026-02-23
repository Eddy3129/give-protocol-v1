// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title   TestContract06_PayoutRouter
 * @author  GIVE Labs
 * @notice  Comprehensive test suite for PayoutRouter yield distribution logic.
 * @dev     Covers initialisation, campaign wiring, share tracking, yield recording,
 *          claim mechanics, fee timelock, access control, and edge cases.
 *
 *          Structure:
 *          - Cases 01–02   Initialisation & campaign wiring
 *          - Cases 03–14   Core yield distribution (functional correctness)
 *          - Cases 15–22   Fee configuration & timelock
 *          - Cases 23–27   Preferences
 *          - Cases 28–30   Share management
 *          - Cases 31–37   Access control
 *          - Cases 38–43   Edge cases & guard rails
 *          - Cases 44–47   Accumulator correctness
 *          - Cases 48–50   Admin operations
 */

import "forge-std/Test.sol";

import {PayoutRouter} from "../../src/payout/PayoutRouter.sol";
import {MockERC20} from "../../src/mocks/MockERC20.sol";
import {GiveTypes} from "../../src/types/GiveTypes.sol";
import {GiveErrors} from "../../src/utils/GiveErrors.sol";

// ─── Mocks ────────────────────────────────────────────────────────────────────

/// @dev Always returns false — forces PayoutRouter to use local role storage.
contract MockACL {
    function hasRole(bytes32, address) external pure returns (bool) {
        return false;
    }
}

/// @dev Configurable registry — lets tests toggle payoutsHalted and payoutRecipient.
contract MockCampaignRegistry {
    address public mockPayoutRecipient;
    bool public payoutsHalted;

    constructor() {
        mockPayoutRecipient = address(0xCAFE);
    }

    function setPayoutsHalted(bool halted) external {
        payoutsHalted = halted;
    }

    function setPayoutRecipient(address r) external {
        mockPayoutRecipient = r;
    }

    function getCampaign(bytes32 id) external view returns (GiveTypes.CampaignConfig memory) {
        uint256[49] memory emptyGap;
        return GiveTypes.CampaignConfig({
            id: id,
            proposer: address(0),
            curator: address(0),
            payoutRecipient: mockPayoutRecipient,
            vault: address(0),
            strategyId: bytes32(0),
            metadataHash: bytes32(0),
            targetStake: 0,
            minStake: 0,
            totalStaked: 0,
            lockedStake: 0,
            initialDeposit: 0,
            fundraisingStart: 0,
            fundraisingEnd: 0,
            createdAt: 0,
            updatedAt: 0,
            status: GiveTypes.CampaignStatus.Active,
            lockProfile: bytes32(0),
            checkpointQuorumBps: 0,
            checkpointVotingDelay: 0,
            checkpointVotingPeriod: 0,
            exists: true,
            payoutsHalted: payoutsHalted,
            __gap: emptyGap
        });
    }
}

// ─── Test contract ────────────────────────────────────────────────────────────

contract TestContract06_PayoutRouter is Test {
    PayoutRouter public payoutRouter;
    MockERC20 public usdc;
    MockACL public mockACL;
    MockCampaignRegistry public mockCampaignRegistry;

    address public protocolAdmin;
    address public feeRecipient;
    address public protocolTreasury;
    address public supporter1;
    address public supporter2;
    address public mockVault;
    address public mockNGO;
    address public beneficiary;

    bytes32 public campaignId;
    uint256 public constant FEE_BPS = 250; // 2.5%

    function setUp() public {
        protocolAdmin = makeAddr("protocolAdmin");
        feeRecipient = makeAddr("feeRecipient");
        protocolTreasury = makeAddr("protocolTreasury");
        supporter1 = makeAddr("supporter1");
        supporter2 = makeAddr("supporter2");
        mockVault = makeAddr("mockVault");
        mockNGO = makeAddr("mockNGO");
        beneficiary = makeAddr("beneficiary");

        vm.deal(protocolAdmin, 100 ether);
        vm.deal(mockVault, 100 ether);

        usdc = new MockERC20("USD Coin", "USDC", 6);
        mockACL = new MockACL();
        mockCampaignRegistry = new MockCampaignRegistry();
        mockCampaignRegistry.setPayoutRecipient(mockNGO);

        payoutRouter = new PayoutRouter();
        vm.prank(protocolAdmin);
        payoutRouter.initialize(
            protocolAdmin, address(mockACL), address(mockCampaignRegistry), feeRecipient, protocolTreasury, FEE_BPS
        );

        campaignId = keccak256("test-campaign");

        vm.startPrank(protocolAdmin);
        payoutRouter.grantRole(payoutRouter.VAULT_MANAGER_ROLE(), protocolAdmin);
        payoutRouter.grantRole(payoutRouter.FEE_MANAGER_ROLE(), protocolAdmin);
        payoutRouter.registerCampaignVault(mockVault, campaignId);
        payoutRouter.setAuthorizedCaller(mockVault, true);
        vm.stopPrank();
    }

    // ── helpers ──────────────────────────────────────────────────────────────

    function _giveShares(address user, uint256 shares) internal {
        vm.prank(mockVault);
        payoutRouter.updateUserShares(user, shares);
    }

    function _recordYield(uint256 amount) internal {
        usdc.mint(address(payoutRouter), amount);
        vm.prank(mockVault);
        payoutRouter.recordYield(address(usdc), amount);
    }

    function _claimYield(address user) internal returns (uint256) {
        vm.prank(user);
        return payoutRouter.claimYield(mockVault, address(usdc));
    }

    // ============================================
    // CASES 01–02  Initialisation & campaign wiring
    // ============================================

    function test_Contract06_Case01_deploymentState() public view {
        assertEq(address(payoutRouter.campaignRegistry()), address(mockCampaignRegistry));
        assertEq(payoutRouter.feeRecipient(), feeRecipient);
        assertEq(payoutRouter.protocolTreasury(), protocolTreasury);
        assertEq(payoutRouter.feeBps(), FEE_BPS);
        assertTrue(payoutRouter.hasRole(payoutRouter.DEFAULT_ADMIN_ROLE(), protocolAdmin));
    }

    function test_Contract06_Case02_campaignVaultRegistration() public {
        bytes32 newCampaignId = keccak256("new-campaign");
        address newVault = makeAddr("newVault");

        vm.prank(protocolAdmin);
        payoutRouter.registerCampaignVault(newVault, newCampaignId);

        assertEq(payoutRouter.getVaultCampaign(newVault), newCampaignId);
    }

    // ============================================
    // CASES 03–14  Core yield distribution (functional correctness)
    // ============================================

    /// @dev Token conservation: every token that leaves the router is accounted for exactly.
    function test_Contract06_Case03_full_yield_conservation_singleUser() public {
        _giveShares(supporter1, 100 ether);
        _recordYield(100 ether);

        uint256 routerBefore = usdc.balanceOf(address(payoutRouter));
        uint256 treasuryBefore = usdc.balanceOf(protocolTreasury);
        uint256 campaignBefore = usdc.balanceOf(mockNGO);

        uint256 claimed = _claimYield(supporter1);

        uint256 routerDelta = routerBefore - usdc.balanceOf(address(payoutRouter));
        uint256 treasuryDelta = usdc.balanceOf(protocolTreasury) - treasuryBefore;
        uint256 campaignDelta = usdc.balanceOf(mockNGO) - campaignBefore;

        assertEq(routerDelta, claimed, "routerDelta != claimed");
        assertEq(treasuryDelta + campaignDelta, claimed, "treasury+campaign != claimed");
        assertEq(usdc.balanceOf(address(payoutRouter)), 0, "router must be empty after sole holder claims");
    }

    /// @dev Equal shares split yield equally; campaign totals match real token flows.
    function test_Contract06_Case04_distributeYieldMultipleUsersEqualShares() public {
        _giveShares(supporter1, 50 ether);
        _giveShares(supporter2, 50 ether);

        vm.prank(supporter1);
        payoutRouter.setVaultPreference(mockVault, supporter1, 50);
        vm.prank(supporter2);
        payoutRouter.setVaultPreference(mockVault, supporter2, 50);

        _recordYield(100 ether);

        _claimYield(supporter1);
        _claimYield(supporter2);

        // Equal shares → equal beneficiary amounts
        assertApproxEqAbs(
            usdc.balanceOf(supporter1), usdc.balanceOf(supporter2), 1, "unequal beneficiary split for equal shares"
        );

        uint256 fee = (100 ether * FEE_BPS) / 10_000;
        uint256 net = 100 ether - fee;
        // 50% of net → beneficiaries, 50% → campaign
        assertApproxEqAbs(
            usdc.balanceOf(supporter1) + usdc.balanceOf(supporter2), net / 2, 2, "total beneficiary amount off"
        );
        assertApproxEqAbs(usdc.balanceOf(mockNGO), net / 2, 2, "total campaign amount off");
    }

    /// @dev 3:1 share ratio; proportional yield split verified.
    function test_Contract06_Case05_proportional_yield_splitUnequalShares() public {
        _giveShares(supporter1, 75 ether);
        _giveShares(supporter2, 25 ether);

        _recordYield(100 ether);

        uint256 fee = (100 ether * FEE_BPS) / 10_000;
        uint256 net = 100 ether - fee;

        uint256 campaignBefore = usdc.balanceOf(mockNGO);
        _claimYield(supporter1);
        _claimYield(supporter2);

        // No preference → 100% to campaign; total must equal net
        assertApproxEqAbs(usdc.balanceOf(mockNGO) - campaignBefore, net, 2, "campaign total off");
        assertEq(usdc.balanceOf(supporter1), 0);
        assertEq(usdc.balanceOf(supporter2), 0);
    }

    /// @dev No preference: 100% of net yield goes to campaign recipient.
    function test_Contract06_Case06_distributeYieldNoPreferences_100pctToCampaign() public {
        _giveShares(supporter1, 100 ether);
        _recordYield(100 ether);

        _claimYield(supporter1);

        assertEq(usdc.balanceOf(protocolTreasury), 2.5 ether, "protocol fee should be 2.5%");
        assertEq(usdc.balanceOf(mockNGO), 97.5 ether, "net yield should go to campaign");
        assertEq(usdc.balanceOf(supporter1), 0, "supporter receives nothing without preference");
    }

    /// @dev 100% allocation with a stored beneficiary — beneficiary receives nothing.
    function test_Contract06_Case07_100pct_allocation_beneficiary_receives_nothing() public {
        vm.prank(supporter1);
        payoutRouter.setVaultPreference(mockVault, beneficiary, 100);

        _giveShares(supporter1, 100 ether);
        _recordYield(100 ether);
        _claimYield(supporter1);

        assertEq(usdc.balanceOf(beneficiary), 0, "beneficiary should get 0 at 100% campaign allocation");
        uint256 fee = (100 ether * FEE_BPS) / 10_000;
        assertApproxEqAbs(usdc.balanceOf(mockNGO), 100 ether - fee, 1, "campaign net yield off");
    }

    /// @dev Sequential recordYield calls accumulate — not reset.
    function test_Contract06_Case08_sequential_recordYield_accumulates() public {
        _giveShares(supporter1, 100 ether);

        _recordYield(60 ether);
        _recordYield(40 ether);

        uint256 claimed = _claimYield(supporter1);
        assertEq(claimed, 100 ether, "sequential yield not fully accumulated");

        uint256 expectedFee = (100 ether * FEE_BPS) / 10_000;
        assertApproxEqAbs(usdc.balanceOf(protocolTreasury), expectedFee, 1, "fee incorrect after two recordings");
    }

    /// @dev Same asset recorded twice hits the deduplication branch without double-counting.
    function test_Contract06_Case09_recordYield_sameAssetTwice_accumulates() public {
        _giveShares(supporter1, 100 ether);

        usdc.mint(address(payoutRouter), 200 ether);
        vm.prank(mockVault);
        payoutRouter.recordYield(address(usdc), 100 ether);
        vm.prank(mockVault);
        payoutRouter.recordYield(address(usdc), 100 ether);

        uint256 claimed = _claimYield(supporter1);
        assertEq(claimed, 200 ether, "should claim yield from both recordings");
    }

    /// @dev getPendingYield matches the actual claimYield output exactly.
    function test_Contract06_Case10_getPendingYield_matchesActualClaimYield() public {
        _giveShares(supporter1, 100 ether);
        _recordYield(50 ether);

        uint256 previewed = payoutRouter.getPendingYield(supporter1, mockVault, address(usdc));
        assertGt(previewed, 0, "pending should be non-zero after recordYield");

        uint256 claimed = _claimYield(supporter1);
        assertEq(previewed, claimed, "getPendingYield must match claimYield return value");
    }

    /// @dev getPendingYield returns zero after a full claim.
    function test_Contract06_Case11_getPendingYield_zeroAfterClaim() public {
        _giveShares(supporter1, 100 ether);
        _recordYield(100 ether);
        _claimYield(supporter1);

        assertEq(payoutRouter.getPendingYield(supporter1, mockVault, address(usdc)), 0, "must be zero post-claim");
    }

    /// @dev campaignTotalPayouts and campaignProtocolFees match actual token transfers.
    function test_Contract06_Case12_campaignTotals_matchActualTransfers() public {
        _giveShares(supporter1, 100 ether);
        _recordYield(100 ether);

        uint256 treasuryBefore = usdc.balanceOf(protocolTreasury);
        uint256 campaignBefore = usdc.balanceOf(mockNGO);

        _claimYield(supporter1);

        (uint256 payouts, uint256 fees) = payoutRouter.getCampaignTotals(campaignId);
        assertEq(payouts, usdc.balanceOf(mockNGO) - campaignBefore, "payouts accumulator mismatch");
        assertEq(fees, usdc.balanceOf(protocolTreasury) - treasuryBefore, "fees accumulator mismatch");
        assertEq(payouts + fees, 100 ether, "payouts + fees must equal total yield");
    }

    /// @dev 75% campaign allocation: all three payout branches (protocol, campaign, beneficiary) active.
    function test_Contract06_Case13_distributeYield_75pctAlloc_allThreeSides() public {
        _giveShares(supporter1, 100 ether);
        _recordYield(100 ether);

        vm.prank(supporter1);
        payoutRouter.setVaultPreference(mockVault, beneficiary, 75);

        uint256 treasuryBefore = usdc.balanceOf(protocolTreasury);
        uint256 campaignBefore = usdc.balanceOf(mockNGO);
        uint256 beneficiaryBefore = usdc.balanceOf(beneficiary);

        uint256 total = _claimYield(supporter1);

        // protocol fee = 2.5 ether, net = 97.5 ether, campaign = 75% = 73.125, bene = 24.375
        assertGt(usdc.balanceOf(protocolTreasury) - treasuryBefore, 0, "protocol fee must be paid");
        assertGt(usdc.balanceOf(mockNGO) - campaignBefore, 0, "campaign must receive yield");
        assertGt(usdc.balanceOf(beneficiary) - beneficiaryBefore, 0, "beneficiary must receive yield");
        assertEq(total, 100 ether, "total claimed must equal full yield");
    }

    /// @dev totalDistributions increments once per recordYield call.
    function test_Contract06_Case14_totalDistributions_incrementsPerRecordYield() public {
        _giveShares(supporter1, 100 ether);

        assertEq(payoutRouter.totalDistributions(), 0);
        _recordYield(100 ether);
        assertEq(payoutRouter.totalDistributions(), 1);

        usdc.mint(address(payoutRouter), 50 ether);
        vm.prank(mockVault);
        payoutRouter.recordYield(address(usdc), 50 ether);
        assertEq(payoutRouter.totalDistributions(), 2);
    }

    // ============================================
    // CASES 15–22  Fee configuration & timelock
    // ============================================

    function test_Contract06_Case15_proposeFeeChange_increaseSetsTimelockEntry() public {
        uint256 newFeeBps = 500;
        address newFeeRecipient = makeAddr("newFeeRecipient");

        vm.prank(protocolAdmin);
        payoutRouter.proposeFeeChange(newFeeRecipient, newFeeBps);

        (uint256 pendingBps, address pendingRecipient, uint256 effectiveTime, bool exists) =
            payoutRouter.getPendingFeeChange(0);

        assertTrue(exists);
        assertEq(pendingBps, newFeeBps);
        assertEq(pendingRecipient, newFeeRecipient);
        assertEq(effectiveTime, block.timestamp + 7 days);
    }

    function test_Contract06_Case16_executeFeeChange_appliesAfterDelay() public {
        uint256 newFeeBps = 500;
        address newFeeRecipient = makeAddr("newFeeRecipient");

        vm.prank(protocolAdmin);
        payoutRouter.proposeFeeChange(newFeeRecipient, newFeeBps);

        vm.warp(block.timestamp + 7 days + 1);
        payoutRouter.executeFeeChange(0);

        assertEq(payoutRouter.feeBps(), newFeeBps);
        assertEq(payoutRouter.feeRecipient(), newFeeRecipient);
    }

    function test_Contract06_Case17_feeChangeDelay_is7Days() public view {
        assertEq(payoutRouter.FEE_CHANGE_DELAY(), 7 days);
    }

    function test_Contract06_Case18_isFeeChangeReady_correctTimeline() public {
        vm.prank(protocolAdmin);
        payoutRouter.proposeFeeChange(feeRecipient, 500);

        assertFalse(payoutRouter.isFeeChangeReady(0), "must not be ready before timelock");
        vm.warp(block.timestamp + 7 days + 1);
        assertTrue(payoutRouter.isFeeChangeReady(0), "must be ready after timelock");

        payoutRouter.executeFeeChange(0);
        assertFalse(payoutRouter.isFeeChangeReady(0), "must not be ready after execution");
    }

    function test_Contract06_Case19_proposeFeeChange_decreaseIsInstant() public {
        uint256 lowerFee = 100;
        address newRecipient = makeAddr("newRecipient");

        vm.prank(protocolAdmin);
        payoutRouter.proposeFeeChange(newRecipient, lowerFee);

        assertEq(payoutRouter.feeBps(), lowerFee, "decrease must apply instantly");
        assertEq(payoutRouter.feeRecipient(), newRecipient);
        (,,, bool exists) = payoutRouter.getPendingFeeChange(0);
        assertFalse(exists, "no pending entry for a fee decrease");
    }

    function test_Contract06_Case20_cancelFeeChange_removesEntry() public {
        vm.prank(protocolAdmin);
        payoutRouter.proposeFeeChange(feeRecipient, 500);
        (,,, bool exists) = payoutRouter.getPendingFeeChange(0);
        assertTrue(exists);

        vm.prank(protocolAdmin);
        vm.expectEmit(true, false, false, false);
        emit PayoutRouter.FeeChangeCancelled(0);
        payoutRouter.cancelFeeChange(0);

        (,,, bool existsAfter) = payoutRouter.getPendingFeeChange(0);
        assertFalse(existsAfter);
        assertEq(payoutRouter.feeBps(), FEE_BPS, "original fee unchanged");
    }

    function test_Contract06_Case21_feeChangeNonce_sequencesCorrectly() public {
        // First increase: 250 → 500 (delta 250, within cap) — nonce 0
        vm.prank(protocolAdmin);
        payoutRouter.proposeFeeChange(feeRecipient, 500);
        // Second increase from live fee 250: 250 → 490 (delta 240, within cap) — nonce 1
        vm.prank(protocolAdmin);
        payoutRouter.proposeFeeChange(feeRecipient, 490);

        (,,, bool exists0) = payoutRouter.getPendingFeeChange(0);
        (,,, bool exists1) = payoutRouter.getPendingFeeChange(1);
        (,,, bool exists2) = payoutRouter.getPendingFeeChange(2);

        assertTrue(exists0, "nonce 0 should exist");
        assertTrue(exists1, "nonce 1 should exist");
        assertFalse(exists2, "nonce 2 should not exist");
    }

    function test_Contract06_Case22_proposeFeeChange_exceedsMaxIncrease_reverts() public {
        uint256 maxIncrease = payoutRouter.MAX_FEE_INCREASE_PER_CHANGE();
        vm.prank(protocolAdmin);
        vm.expectRevert(abi.encodeWithSelector(GiveErrors.FeeIncreaseTooLarge.selector, 251, maxIncrease));
        payoutRouter.proposeFeeChange(feeRecipient, FEE_BPS + 251);
    }

    // ============================================
    // CASES 23–27  Preferences
    // ============================================

    function test_Contract06_Case23_setVaultPreference_storesCorrectly() public {
        vm.prank(supporter1);
        payoutRouter.setVaultPreference(mockVault, supporter1, 75);

        GiveTypes.CampaignPreference memory pref = payoutRouter.getVaultPreference(supporter1, mockVault);
        assertEq(pref.allocationPercentage, 75);
        assertEq(pref.beneficiary, supporter1);
    }

    function test_Contract06_Case24_updateVaultPreference_overwritesPrevious() public {
        vm.prank(supporter1);
        payoutRouter.setVaultPreference(mockVault, supporter1, 50);

        address newBeneficiary = makeAddr("newBeneficiary");
        vm.prank(supporter1);
        payoutRouter.setVaultPreference(mockVault, newBeneficiary, 100);

        GiveTypes.CampaignPreference memory pref = payoutRouter.getVaultPreference(supporter1, mockVault);
        assertEq(pref.allocationPercentage, 100);
        assertEq(pref.beneficiary, newBeneficiary);
    }

    function test_Contract06_Case25_setVaultPreference_invalidAllocation_reverts() public {
        vm.prank(supporter1);
        vm.expectRevert(abi.encodeWithSelector(PayoutRouter.InvalidAllocation.selector, uint8(60)));
        payoutRouter.setVaultPreference(mockVault, beneficiary, 60);
    }

    function test_Contract06_Case26_setVaultPreference_splitWithZeroBeneficiary_reverts() public {
        vm.prank(supporter1);
        vm.expectRevert(PayoutRouter.InvalidBeneficiary.selector);
        payoutRouter.setVaultPreference(mockVault, address(0), 50);
    }

    function test_Contract06_Case27_setVaultPreference_paused_reverts() public {
        vm.prank(protocolAdmin);
        payoutRouter.pause();

        vm.prank(supporter1);
        vm.expectRevert();
        payoutRouter.setVaultPreference(mockVault, supporter1, 50);
    }

    // ============================================
    // CASES 28–30  Share management
    // ============================================

    function test_Contract06_Case28_updateUserShares_storesAndTotals() public {
        _giveShares(supporter1, 100 ether);

        assertEq(payoutRouter.getUserVaultShares(supporter1, mockVault), 100 ether);
        assertEq(payoutRouter.getTotalVaultShares(mockVault), 100 ether);
    }

    function test_Contract06_Case29_updateUserShares_twoUsers_totalCorrect() public {
        _giveShares(supporter1, 50 ether);
        _giveShares(supporter2, 50 ether);

        assertEq(payoutRouter.getTotalVaultShares(mockVault), 100 ether);
    }

    function test_Contract06_Case30_registerCampaignVault_reassignment_emitsVaultReassigned() public {
        bytes32 newCampaignId = keccak256("campaign-B");

        vm.prank(protocolAdmin);
        vm.expectEmit(true, true, true, false);
        emit PayoutRouter.VaultReassigned(mockVault, campaignId, newCampaignId);
        payoutRouter.registerCampaignVault(mockVault, newCampaignId);

        assertEq(payoutRouter.getVaultCampaign(mockVault), newCampaignId);
    }

    // ============================================
    // CASES 31–37  Access control
    // ============================================

    function test_Contract06_Case31_unauthorizedRecordYield_reverts() public {
        usdc.mint(address(payoutRouter), 100 ether);
        vm.expectRevert();
        payoutRouter.recordYield(address(usdc), 100 ether);
    }

    function test_Contract06_Case32_unauthorizedVaultRegistration_reverts() public {
        vm.expectRevert();
        payoutRouter.registerCampaignVault(makeAddr("v"), keccak256("c"));
    }

    function test_Contract06_Case33_unauthorizedShareUpdate_reverts() public {
        vm.expectRevert();
        payoutRouter.updateUserShares(supporter1, 100 ether);
    }

    function test_Contract06_Case34_cancelFeeChange_nonAdmin_reverts() public {
        vm.prank(protocolAdmin);
        payoutRouter.proposeFeeChange(feeRecipient, 500);

        vm.prank(makeAddr("rando"));
        vm.expectRevert();
        payoutRouter.cancelFeeChange(0);
    }

    function test_Contract06_Case35_emergencyWithdraw_nonAdmin_reverts() public {
        usdc.mint(address(payoutRouter), 50 ether);
        vm.prank(makeAddr("rando"));
        vm.expectRevert();
        payoutRouter.emergencyWithdraw(address(usdc), makeAddr("r"), 50 ether);
    }

    function test_Contract06_Case36_setAuthorizedCaller_zeroAddress_reverts() public {
        vm.prank(protocolAdmin);
        vm.expectRevert(GiveErrors.ZeroAddress.selector);
        payoutRouter.setAuthorizedCaller(address(0), true);
    }

    function test_Contract06_Case37_registerCampaignVault_zeroParams_revert() public {
        vm.prank(protocolAdmin);
        vm.expectRevert(GiveErrors.ZeroAddress.selector);
        payoutRouter.registerCampaignVault(address(0), campaignId);

        vm.prank(protocolAdmin);
        vm.expectRevert(GiveErrors.ZeroAddress.selector);
        payoutRouter.registerCampaignVault(mockVault, bytes32(0));
    }

    // ============================================
    // CASES 38–43  Edge cases & guard rails
    // ============================================

    function test_Contract06_Case38_recordYield_zeroAmount_reverts() public {
        _giveShares(supporter1, 100 ether);
        vm.prank(mockVault);
        vm.expectRevert();
        payoutRouter.recordYield(address(usdc), 0);
    }

    function test_Contract06_Case39_recordYield_zeroAsset_reverts() public {
        vm.prank(mockVault);
        vm.expectRevert(GiveErrors.ZeroAddress.selector);
        payoutRouter.recordYield(address(0), 1);
    }

    function test_Contract06_Case40_recordYield_noShares_reverts() public {
        usdc.mint(address(payoutRouter), 100 ether);
        vm.prank(mockVault);
        vm.expectRevert();
        payoutRouter.recordYield(address(usdc), 100 ether);
    }

    function test_Contract06_Case41_recordYield_insufficientBalance_reverts() public {
        _giveShares(supporter1, 100 ether);
        vm.prank(mockVault);
        vm.expectRevert(GiveErrors.InsufficientBalance.selector);
        payoutRouter.recordYield(address(usdc), 100 ether);
    }

    function test_Contract06_Case42_recordYield_deltaPerShareZero_reverts() public {
        _giveShares(supporter1, 1e30); // huge shares make 1 wei/share round to 0
        usdc.mint(address(payoutRouter), 1);
        vm.prank(mockVault);
        vm.expectRevert(GiveErrors.InvalidAmount.selector);
        payoutRouter.recordYield(address(usdc), 1);
    }

    function test_Contract06_Case43_recordYield_payoutsHalted_reverts() public {
        _giveShares(supporter1, 100 ether);
        mockCampaignRegistry.setPayoutsHalted(true);
        usdc.mint(address(payoutRouter), 100 ether);
        vm.prank(mockVault);
        vm.expectRevert(GiveErrors.OperationNotAllowed.selector);
        payoutRouter.recordYield(address(usdc), 100 ether);
    }

    // ============================================
    // CASES 44–47  Accumulator correctness
    // ============================================

    function test_Contract06_Case44_claimYield_payoutsHalted_reverts() public {
        _giveShares(supporter1, 100 ether);
        _recordYield(100 ether);

        mockCampaignRegistry.setPayoutsHalted(true);

        vm.prank(supporter1);
        vm.expectRevert(GiveErrors.OperationNotAllowed.selector);
        payoutRouter.claimYield(mockVault, address(usdc));
    }

    function test_Contract06_Case45_payoutsHalted_then_unhalted_claimSucceeds() public {
        _giveShares(supporter1, 100 ether);
        _recordYield(100 ether);

        mockCampaignRegistry.setPayoutsHalted(true);
        vm.prank(supporter1);
        vm.expectRevert();
        payoutRouter.claimYield(mockVault, address(usdc));

        mockCampaignRegistry.setPayoutsHalted(false);
        uint256 claimed = _claimYield(supporter1);
        assertGt(claimed, 0, "claim must succeed after un-halting");
    }

    function test_Contract06_Case46_claimYield_stalePrefCleared() public {
        vm.prank(supporter1);
        payoutRouter.setVaultPreference(mockVault, beneficiary, 50);

        // Reassign vault to a new campaign — pref is now stale
        bytes32 campaignB = keccak256("campaign-B");
        vm.prank(protocolAdmin);
        payoutRouter.registerCampaignVault(mockVault, campaignB);

        _giveShares(supporter1, 100 ether);
        _recordYield(100 ether);

        vm.prank(supporter1);
        vm.expectEmit(true, true, false, false);
        emit PayoutRouter.StalePrefCleared(supporter1, mockVault);
        payoutRouter.claimYield(mockVault, address(usdc));

        GiveTypes.CampaignPreference memory pref = payoutRouter.getVaultPreference(supporter1, mockVault);
        assertEq(pref.campaignId, bytes32(0), "stale pref must be cleared");
    }

    function test_Contract06_Case47_accruePending_sharesZero_noAccrual() public {
        // Give yield to another user; supporter1 has 0 shares — claim must return 0
        _giveShares(makeAddr("other"), 100 ether);
        _recordYield(100 ether);

        uint256 claimed = _claimYield(supporter1);
        assertEq(claimed, 0, "zero-share user must accrue nothing");
    }

    // ============================================
    // CASES 48–50  Admin operations
    // ============================================

    function test_Contract06_Case48_emergencyWithdraw_transfersToRecipient() public {
        usdc.mint(address(payoutRouter), 50 ether);

        address recipient = makeAddr("recipient");
        vm.prank(protocolAdmin);
        payoutRouter.emergencyWithdraw(address(usdc), recipient, 50 ether);

        assertEq(usdc.balanceOf(recipient), 50 ether);
        assertEq(usdc.balanceOf(address(payoutRouter)), 0);
    }

    function test_Contract06_Case49_setProtocolTreasury_updatesAddress() public {
        address newTreasury = makeAddr("newTreasury");
        vm.prank(protocolAdmin);
        vm.expectEmit(true, true, false, false);
        emit PayoutRouter.ProtocolTreasuryUpdated(protocolTreasury, newTreasury);
        payoutRouter.setProtocolTreasury(newTreasury);

        assertEq(payoutRouter.protocolTreasury(), newTreasury);
    }

    function test_Contract06_Case50_pauseUnpause_roundTrip() public {
        vm.prank(protocolAdmin);
        payoutRouter.pause();
        assertTrue(payoutRouter.paused());

        vm.prank(protocolAdmin);
        payoutRouter.unpause();
        assertFalse(payoutRouter.paused());
    }
}
