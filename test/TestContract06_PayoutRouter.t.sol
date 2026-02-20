// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";

import {PayoutRouter} from "../src/payout/PayoutRouter.sol";
import {MockERC20} from "../src/mocks/MockERC20.sol";
import {GiveTypes} from "../src/types/GiveTypes.sol";

/**
 * @title MockACL
 * @notice Simple mock ACL that always returns false (relies on local roles)
 */
contract MockACL {
    function hasRole(bytes32, address) external pure returns (bool) {
        return false; // Always return false, forcing PayoutRouter to use local roles
    }
}

/**
 * @title MockCampaignRegistry
 * @notice Simple mock registry that returns a valid campaign config
 */
contract MockCampaignRegistry {
    address public mockPayoutRecipient;

    constructor() {
        mockPayoutRecipient = address(0xCAFE); // Valid non-zero address for campaign payouts
    }

    function getCampaign(bytes32 _id) external view returns (GiveTypes.CampaignConfig memory) {
        // Create and return empty gap array
        uint256[49] memory emptyGap;

        return GiveTypes.CampaignConfig({
            id: _id,
            proposer: address(0),
            curator: address(0),
            payoutRecipient: mockPayoutRecipient, // MUST be non-zero to avoid ERC20InvalidReceiver
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
            payoutsHalted: false,
            __gap: emptyGap
        });
    }
}

/**
 * @title TestContract06_PayoutRouter
 * @notice Comprehensive test suite for PayoutRouter payout distribution logic
 * @dev Simplified test focusing on PayoutRouter logic without full protocol integration
 */
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

        // Fund addresses with ETH
        vm.deal(protocolAdmin, 100 ether);
        vm.deal(supporter1, 100 ether);
        vm.deal(supporter2, 100 ether);
        vm.deal(mockVault, 100 ether);

        // Deploy mock contracts
        usdc = new MockERC20("USD Coin", "USDC", 6);
        mockACL = new MockACL();
        mockCampaignRegistry = new MockCampaignRegistry();

        // Deploy PayoutRouter with mock dependencies
        payoutRouter = new PayoutRouter();

        vm.prank(protocolAdmin);
        payoutRouter.initialize(
            protocolAdmin, address(mockACL), address(mockCampaignRegistry), feeRecipient, protocolTreasury, FEE_BPS
        );

        // Set up mock vault as authorized caller
        campaignId = keccak256("test-campaign");

        vm.startPrank(protocolAdmin);
        // Grant necessary roles to protocolAdmin
        payoutRouter.grantRole(payoutRouter.VAULT_MANAGER_ROLE(), protocolAdmin);
        payoutRouter.grantRole(payoutRouter.FEE_MANAGER_ROLE(), protocolAdmin);

        // Register vault and authorize it
        payoutRouter.registerCampaignVault(mockVault, campaignId);
        payoutRouter.setAuthorizedCaller(mockVault, true);
        vm.stopPrank();
    }

    // ============================================
    // INITIALIZATION TESTS
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
    // PAYOUT DISTRIBUTION TESTS (PULL MODEL)
    // ============================================

    function test_Contract06_Case03_distributeYieldBasic() public {
        // Setup: Give supporter1 50% of vault shares
        vm.prank(mockVault);
        payoutRouter.updateUserShares(supporter1, 100 ether);

        // Setup supporter preferences (50% to campaign, 50% to supporter1)
        vm.prank(supporter1);
        payoutRouter.setVaultPreference(mockVault, supporter1, 50);

        // Mint USDC to PayoutRouter (not vault)
        usdc.mint(address(payoutRouter), 100 ether);

        // Record yield from vault
        vm.prank(mockVault);
        payoutRouter.recordYield(address(usdc), 100 ether);

        // User claims
        vm.prank(supporter1);
        payoutRouter.claimYield(mockVault, address(usdc));

        // Verify protocol fee was taken (2.5%) and sent to protocolTreasury
        assertEq(usdc.balanceOf(protocolTreasury), 2.5 ether);

        // Verify supporter got their portion
        assertTrue(usdc.balanceOf(supporter1) > 0);
    }

    function test_Contract06_Case04_distributeYieldMultipleUsers() public {
        // Give both supporters equal shares
        vm.startPrank(mockVault);
        payoutRouter.updateUserShares(supporter1, 50 ether);
        payoutRouter.updateUserShares(supporter2, 50 ether);
        vm.stopPrank();

        // Set preferences (valid allocations: 50, 75, 100)
        vm.prank(supporter1);
        payoutRouter.setVaultPreference(mockVault, supporter1, 50);

        vm.prank(supporter2);
        payoutRouter.setVaultPreference(mockVault, supporter2, 75);

        // Mint USDC to PayoutRouter
        usdc.mint(address(payoutRouter), 100 ether);

        // Record yield
        vm.prank(mockVault);
        payoutRouter.recordYield(address(usdc), 100 ether);

        // Users claim independently
        vm.prank(supporter1);
        payoutRouter.claimYield(mockVault, address(usdc));
        vm.prank(supporter2);
        payoutRouter.claimYield(mockVault, address(usdc));

        // Both supporters should receive yield
        assertTrue(usdc.balanceOf(supporter1) > 0);
        assertTrue(usdc.balanceOf(supporter2) > 0);

        // Protocol fee should be collected and sent to protocolTreasury
        assertEq(usdc.balanceOf(protocolTreasury), 2.5 ether);
    }

    function test_Contract06_Case05_distributeYieldNoPreferences() public {
        // Give supporter shares but no preferences set
        vm.prank(mockVault);
        payoutRouter.updateUserShares(supporter2, 100 ether);

        // Mint USDC to PayoutRouter
        usdc.mint(address(payoutRouter), 100 ether);

        // Record yield
        vm.prank(mockVault);
        payoutRouter.recordYield(address(usdc), 100 ether);

        // User claims
        vm.prank(supporter2);
        payoutRouter.claimYield(mockVault, address(usdc));

        // Protocol fee should be taken and sent to protocolTreasury (2.5%)
        assertEq(usdc.balanceOf(protocolTreasury), 2.5 ether);

        // With no preference set, default is 100% to campaign recipient (not supporter)
        // Net yield after protocol fee: 100 - 2.5 = 97.5 ether goes to campaign
        assertEq(usdc.balanceOf(mockCampaignRegistry.mockPayoutRecipient()), 97.5 ether);

        // Supporter gets nothing when no preference is set (default = 100% to campaign)
        assertEq(usdc.balanceOf(supporter2), 0);
    }

    // ============================================
    // FEE CONFIGURATION TESTS
    // ============================================

    function test_Contract06_Case06_proposeFeeChange() public {
        uint256 newFeeBps = 500; // 5%
        address newFeeRecipient = makeAddr("newFeeRecipient");

        vm.prank(protocolAdmin);
        payoutRouter.proposeFeeChange(newFeeRecipient, newFeeBps);

        // Verify pending change was created at nonce 0 (first fee change)
        (uint256 pendingBps, address pendingRecipient, uint256 effectiveTime, bool exists) =
            payoutRouter.getPendingFeeChange(0);

        assertTrue(exists);
        assertEq(pendingBps, newFeeBps);
        assertEq(pendingRecipient, newFeeRecipient);
        assertEq(effectiveTime, block.timestamp + 7 days);
    }

    function test_Contract06_Case07_executeFeeChange() public {
        uint256 newFeeBps = 500; // 5%
        address newFeeRecipient = makeAddr("newFeeRecipient");

        // Propose change
        vm.prank(protocolAdmin);
        payoutRouter.proposeFeeChange(newFeeRecipient, newFeeBps);

        // Fast forward past timelock
        vm.warp(block.timestamp + 7 days + 1);

        // Execute change at nonce 0 (first fee change)
        payoutRouter.executeFeeChange(0);

        // Verify change was applied
        assertEq(payoutRouter.feeBps(), newFeeBps);
        assertEq(payoutRouter.feeRecipient(), newFeeRecipient);
    }

    function test_Contract06_Case08_feeTimelock() public view {
        // Verify timelock is set
        uint256 timelock = payoutRouter.FEE_CHANGE_DELAY();
        assertEq(timelock, 7 days);
    }

    // ============================================
    // PREFERENCES TESTS
    // ============================================

    function test_Contract06_Case09_setVaultPreference() public {
        vm.prank(supporter1);
        payoutRouter.setVaultPreference(mockVault, supporter1, 75); // Valid allocation

        GiveTypes.CampaignPreference memory pref = payoutRouter.getVaultPreference(supporter1, mockVault);
        assertEq(pref.allocationPercentage, 75);
        assertEq(pref.beneficiary, supporter1);
    }

    function test_Contract06_Case10_updateVaultPreference() public {
        // Set initial preferences
        vm.prank(supporter1);
        payoutRouter.setVaultPreference(mockVault, supporter1, 50);

        // Update preferences
        address newBeneficiary = makeAddr("newBeneficiary");
        vm.prank(supporter1);
        payoutRouter.setVaultPreference(mockVault, newBeneficiary, 100); // Valid allocation

        GiveTypes.CampaignPreference memory pref = payoutRouter.getVaultPreference(supporter1, mockVault);
        assertEq(pref.allocationPercentage, 100);
        assertEq(pref.beneficiary, newBeneficiary);
    }

    // ============================================
    // SHARE MANAGEMENT TESTS
    // ============================================

    function test_Contract06_Case11_updateUserShares() public {
        vm.prank(mockVault);
        payoutRouter.updateUserShares(supporter1, 100 ether);

        uint256 shares = payoutRouter.getUserVaultShares(supporter1, mockVault);
        assertEq(shares, 100 ether);

        uint256 totalShares = payoutRouter.getTotalVaultShares(mockVault);
        assertEq(totalShares, 100 ether);
    }

    function test_Contract06_Case12_shareholderTracking() public {
        vm.startPrank(mockVault);
        payoutRouter.updateUserShares(supporter1, 50 ether);
        payoutRouter.updateUserShares(supporter2, 50 ether);
        vm.stopPrank();

        // Pull model relies on total shares, not iterable holder tracking
        uint256 totalShares = payoutRouter.getTotalVaultShares(mockVault);
        assertEq(totalShares, 100 ether);
    }

    // ============================================
    // ACCESS CONTROL TESTS
    // ============================================

    function test_Contract06_Case13_unauthorizedDistribution() public {
        usdc.mint(address(payoutRouter), 100 ether);

        // Should revert - not authorized caller
        vm.expectRevert();
        payoutRouter.recordYield(address(usdc), 100 ether);
    }

    function test_Contract06_Case14_unauthorizedVaultRegistration() public {
        bytes32 newCampaignId = keccak256("unauthorized-campaign");
        address newVault = makeAddr("unauthorizedVault");

        // Should revert - not admin
        vm.expectRevert();
        payoutRouter.registerCampaignVault(newVault, newCampaignId);
    }

    function test_Contract06_Case15_unauthorizedShareUpdate() public {
        // Should revert - not authorized caller
        vm.expectRevert();
        payoutRouter.updateUserShares(supporter1, 100 ether);
    }

    // ============================================
    // EDGE CASES
    // ============================================

    function test_Contract06_Case16_zeroAmountDistribution() public {
        usdc.mint(address(payoutRouter), 100 ether);

        vm.prank(mockVault);
        payoutRouter.updateUserShares(supporter1, 100 ether);

        // Should handle zero amount gracefully
        vm.prank(mockVault);
        vm.expectRevert();
        payoutRouter.recordYield(address(usdc), 0);
    }

    function test_Contract06_Case17_maxFeeBpsEnforcement() public {
        // Try to propose fee above maximum
        address newFeeRecipient = makeAddr("newFeeRecipient");

        vm.prank(protocolAdmin);
        vm.expectRevert();
        payoutRouter.proposeFeeChange(newFeeRecipient, 10001); // > 10000 (100%)
    }

    function test_Contract06_Case18_distributeWithNoShares() public {
        usdc.mint(address(payoutRouter), 100 ether);

        // Try to distribute with no shareholders
        vm.prank(mockVault);
        vm.expectRevert();
        payoutRouter.recordYield(address(usdc), 100 ether);
    }

    // ============================================
    // BRANCH GAP COVERAGE (Update J)
    // ============================================

    function test_Contract06_Case19_cancelFeeChange_happyPath() public {
        uint256 newFeeBps = 500;
        address newRecipient = makeAddr("newRecipient");

        vm.prank(protocolAdmin);
        payoutRouter.proposeFeeChange(newRecipient, newFeeBps);

        // Nonce 0 should exist
        (,,, bool exists) = payoutRouter.getPendingFeeChange(0);
        assertTrue(exists);

        vm.prank(protocolAdmin);
        vm.expectEmit(true, false, false, false);
        emit PayoutRouter.FeeChangeCancelled(0);
        payoutRouter.cancelFeeChange(0);

        // Nonce 0 should be gone
        (,,, bool existsAfter) = payoutRouter.getPendingFeeChange(0);
        assertFalse(existsAfter);
        // Original fee unchanged
        assertEq(payoutRouter.feeBps(), FEE_BPS);
    }

    function test_Contract06_Case20_cancelFeeChange_nonExistentNonceReverts() public {
        vm.prank(protocolAdmin);
        vm.expectRevert();
        payoutRouter.cancelFeeChange(999);
    }

    function test_Contract06_Case21_cancelFeeChange_nonAdminReverts() public {
        uint256 newFeeBps = 500;
        address newRecipient = makeAddr("newRecipient");

        vm.prank(protocolAdmin);
        payoutRouter.proposeFeeChange(newRecipient, newFeeBps);

        vm.prank(makeAddr("rando"));
        vm.expectRevert();
        payoutRouter.cancelFeeChange(0);
    }

    function test_Contract06_Case22_emergencyWithdraw_transfersToRecipient() public {
        usdc.mint(address(payoutRouter), 50 ether);

        address recipient = makeAddr("recipient");
        vm.prank(protocolAdmin);
        payoutRouter.emergencyWithdraw(address(usdc), recipient, 50 ether);

        assertEq(usdc.balanceOf(recipient), 50 ether);
        assertEq(usdc.balanceOf(address(payoutRouter)), 0);
    }

    function test_Contract06_Case23_emergencyWithdraw_nonAdminReverts() public {
        usdc.mint(address(payoutRouter), 50 ether);

        vm.prank(makeAddr("rando"));
        vm.expectRevert();
        payoutRouter.emergencyWithdraw(address(usdc), makeAddr("recipient"), 50 ether);
    }

    function test_Contract06_Case24_setProtocolTreasury_updatesAddress() public {
        address newTreasury = makeAddr("newTreasury");
        vm.prank(protocolAdmin);
        vm.expectEmit(true, true, false, false);
        emit PayoutRouter.ProtocolTreasuryUpdated(protocolTreasury, newTreasury);
        payoutRouter.setProtocolTreasury(newTreasury);

        assertEq(payoutRouter.protocolTreasury(), newTreasury);
    }

    function test_Contract06_Case25_pauseUnpause_roundTrip() public {
        vm.prank(protocolAdmin);
        payoutRouter.pause();
        assertTrue(payoutRouter.paused());

        vm.prank(protocolAdmin);
        payoutRouter.unpause();
        assertFalse(payoutRouter.paused());
    }

    function test_Contract06_Case26_claimYield_whenPausedReverts() public {
        vm.prank(mockVault);
        payoutRouter.updateUserShares(supporter1, 100 ether);

        usdc.mint(address(payoutRouter), 100 ether);

        vm.prank(mockVault);
        payoutRouter.recordYield(address(usdc), 100 ether);

        vm.prank(protocolAdmin);
        payoutRouter.pause();

        vm.prank(supporter1);
        vm.expectRevert();
        payoutRouter.claimYield(mockVault, address(usdc));
    }

    function test_Contract06_Case27_claimYield_zeroAccumulatedYieldNoOps() public {
        // supporter1 has shares but no yield has been recorded — claim should return 0
        vm.prank(mockVault);
        payoutRouter.updateUserShares(supporter1, 100 ether);

        vm.prank(supporter1);
        uint256 claimed = payoutRouter.claimYield(mockVault, address(usdc));
        assertEq(claimed, 0);
    }

    function test_Contract06_Case28_proposeFeeChange_decreaseIsInstant() public {
        // Current fee is FEE_BPS (250). Proposing lower should apply immediately.
        uint256 lowerFee = 100;
        address newRecipient = makeAddr("newRecipient");

        vm.prank(protocolAdmin);
        payoutRouter.proposeFeeChange(newRecipient, lowerFee);

        // Applied instantly — no pending change at nonce 0
        assertEq(payoutRouter.feeBps(), lowerFee);
        assertEq(payoutRouter.feeRecipient(), newRecipient);
        (,,, bool exists) = payoutRouter.getPendingFeeChange(0);
        assertFalse(exists);
    }
}
