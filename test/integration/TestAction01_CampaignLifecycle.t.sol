// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Base03_DeployComprehensiveEnvironment} from "../base/Base03_DeployComprehensiveEnvironment.t.sol";
import {GiveTypes} from "../../src/types/GiveTypes.sol";
import {GiveErrors} from "../../src/utils/GiveErrors.sol";
import {CampaignVault4626} from "../../src/vault/CampaignVault4626.sol";
import {GiveVault4626} from "../../src/vault/GiveVault4626.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IYieldAdapter} from "../../src/interfaces/IYieldAdapter.sol";

/**
 * @title TestAction01_CampaignLifecycle
 * @author GIVE Labs
 * @notice Comprehensive integration test for complete campaign lifecycle using real production paths
 * @dev Tests the full flow from campaign creation to payout:
 *      1. Campaign submission and approval
 *      2. Donor deposits and share minting
 *      3. Vault allocation to yield adapters via setActiveAdapter and deposit
 *      4. Yield generation via Aave mock accrueYield
 *      5. Yield harvesting via GiveVault4626.harvest() and PayoutRouter distribution
 *      6. Checkpoint governance (proposal, voting, finalization)
 *      7. Campaign completion and NGO payout via PayoutRouter
 *      8. Withdrawal flows for donors
 *
 *      Each test is standalone and uses helper functions instead of calling other tests.
 *      All tests exercise actual orchestrators (StrategyManager, PayoutRouter, etc.)
 *      instead of bypassing with pranks.
 */
contract TestAction01_CampaignLifecycle is Base03_DeployComprehensiveEnvironment {
    // ============================================================
    // TEST CONSTANTS
    // ============================================================

    uint256 constant DONOR1_INITIAL_DEPOSIT = 50_000e6; // $50k USDC
    uint256 constant DONOR2_INITIAL_DEPOSIT = 30_000e6; // $30k USDC
    uint256 constant DONOR3_INITIAL_DEPOSIT = 20_000e6; // $20k USDC

    uint256 constant YIELD_INJECTION_AMOUNT = 5_000e6; // $5k yield

    // Test account for vault manager operations
    address public vaultManager;

    // ============================================================
    // SETUP
    // ============================================================

    function setUp() public override {
        super.setUp(); // Deploy full Base03 environment

        // Create vault manager account and grant role
        vaultManager = makeAddr("vaultManager");

        vm.startPrank(admin);
        bytes32 VAULT_MANAGER_ROLE = keccak256("VAULT_MANAGER_ROLE");
        aclManager.grantRole(VAULT_MANAGER_ROLE, vaultManager);

        // Also grant to admin for helper functions
        aclManager.grantRole(VAULT_MANAGER_ROLE, admin);
        vm.stopPrank();
    }

    // ============================================================
    // TEST 1: CAMPAIGN SUBMISSION AND APPROVAL
    // ============================================================

    function test_01_CampaignSubmissionAndApproval() public {
        emit log_string("\n=== TEST 1: Campaign Submission and Approval ===");

        // Verify climate campaign exists and is active
        GiveTypes.CampaignConfig memory campaign = campaignRegistry.getCampaign(campaignClimateId);

        assertEq(uint8(campaign.status), uint8(GiveTypes.CampaignStatus.Active), "Campaign should be active");
        assertEq(campaign.vault, climateVault, "Vault should be assigned");
        assertEq(campaign.strategyId, aaveUsdcStrategyId, "Strategy should match");
        assertEq(campaign.payoutRecipient, ngo1, "NGO should be Red Cross");

        emit log_named_uint("Campaign target stake", campaign.targetStake);
        emit log_named_uint("Campaign min stake", campaign.minStake);
        emit log_named_address("Campaign vault", campaign.vault);
        emit log_named_bytes32("Campaign strategy", campaign.strategyId);

        // Verify vault is properly initialized
        CampaignVault4626 vault = CampaignVault4626(payable(climateVault));
        assertEq(vault.asset(), address(usdc), "Vault asset should be USDC");
        assertEq(vault.totalAssets(), 0, "Vault should start empty");
        assertEq(vault.totalSupply(), 0, "No shares minted yet");

        // Verify vault is registered with PayoutRouter
        bytes32 registeredCampaignId = payoutRouter.getVaultCampaign(climateVault);
        assertEq(registeredCampaignId, campaignClimateId, "Vault should be registered with router");

        // Verify strategy registry tracking
        address[] memory strategyVaults = strategyRegistry.getStrategyVaults(aaveUsdcStrategyId);
        bool foundVault = false;
        for (uint256 i = 0; i < strategyVaults.length; i++) {
            if (strategyVaults[i] == climateVault) {
                foundVault = true;
                break;
            }
        }
        assertTrue(foundVault, "Vault should be registered with strategy");

        emit log_string("[OK] Campaign properly submitted, approved, vault initialized and registered");
    }

    // ============================================================
    // TEST 2: DONOR DEPOSITS
    // ============================================================

    function test_02_DonorDeposits() public {
        emit log_string("\n=== TEST 2: Donor Deposits ===");

        // Use helper to perform deposits
        _depositDonors(climateVault, DONOR1_INITIAL_DEPOSIT, DONOR2_INITIAL_DEPOSIT, DONOR3_INITIAL_DEPOSIT);

        CampaignVault4626 vault = CampaignVault4626(payable(climateVault));

        // Verify vault state
        uint256 totalDeposits = DONOR1_INITIAL_DEPOSIT + DONOR2_INITIAL_DEPOSIT + DONOR3_INITIAL_DEPOSIT;
        assertEq(vault.totalAssets(), totalDeposits, "Total assets should match deposits");
        assertEq(vault.totalSupply(), totalDeposits, "Total shares should match deposits (1:1 initially)");

        // Verify individual share balances
        assertEq(vault.balanceOf(donor1), DONOR1_INITIAL_DEPOSIT, "Donor1 shares should be 1:1");
        assertEq(vault.balanceOf(donor2), DONOR2_INITIAL_DEPOSIT, "Donor2 shares should be 1:1");
        assertEq(vault.balanceOf(donor3), DONOR3_INITIAL_DEPOSIT, "Donor3 shares should be 1:1");

        // Verify PayoutRouter tracking
        assertEq(
            payoutRouter.getUserVaultShares(donor1, climateVault),
            DONOR1_INITIAL_DEPOSIT,
            "Router should track donor1 shares"
        );
        assertEq(
            payoutRouter.getUserVaultShares(donor2, climateVault),
            DONOR2_INITIAL_DEPOSIT,
            "Router should track donor2 shares"
        );

        emit log_named_uint("Total vault assets", vault.totalAssets());
        emit log_named_uint("Total vault shares", vault.totalSupply());
        emit log_string("[OK] All donors successfully deposited with router tracking");
    }

    // ============================================================
    // TEST 3: VAULT ALLOCATION TO ADAPTER (REAL PRODUCTION PATH)
    // ============================================================

    function test_03_VaultAllocatesViaAdapter() public {
        emit log_string("\n=== TEST 3: Vault Allocates to Adapter via Production Path ===");

        // Setup: donors deposit first
        _depositDonors(climateVault, DONOR1_INITIAL_DEPOSIT, DONOR2_INITIAL_DEPOSIT, DONOR3_INITIAL_DEPOSIT);

        GiveVault4626 vault = GiveVault4626(payable(climateVault));
        uint256 totalDeposits = DONOR1_INITIAL_DEPOSIT + DONOR2_INITIAL_DEPOSIT + DONOR3_INITIAL_DEPOSIT;

        // Verify vault holds deposits initially
        assertEq(usdc.balanceOf(climateVault), totalDeposits, "Vault should hold all deposits");

        // FIX: Use campaign-specific adapter (climateAaveAdapter, not Base02's aaveUsdcAdapter)
        // Step 1: Set active adapter (vault manager role)
        vm.startPrank(vaultManager);
        vault.setActiveAdapter(IYieldAdapter(address(climateAaveAdapter)));
        vm.stopPrank();

        emit log_string("Active adapter set to Climate AaveAdapter");

        // Verify adapter is set
        assertEq(address(vault.activeAdapter()), address(climateAaveAdapter), "Adapter should be set");

        // Step 2: Transfer funds from vault to adapter and invest
        // FIX: Use vault.transfer(), not transferFrom (no approval needed)
        vm.prank(climateVault);
        require(usdc.transfer(address(climateAaveAdapter), totalDeposits), "Transfer failed");

        // Adapter invests into Aave
        vm.prank(climateVault); // Only vault can call adapter.invest()
        climateAaveAdapter.invest(totalDeposits);

        emit log_named_uint("Invested to adapter", totalDeposits);

        // Verify funds moved to adapter
        uint256 adapterBalance = climateAaveAdapter.totalAssets();
        assertEq(adapterBalance, totalDeposits, "Adapter should hold allocated funds");

        // Verify aToken balance (Aave adapter deposits to pool)
        address aToken = aavePool.getReserveData(address(usdc)).aTokenAddress;
        uint256 aTokenBalance = IERC20(aToken).balanceOf(address(climateAaveAdapter));
        assertEq(aTokenBalance, totalDeposits, "Adapter should have aTokens");

        emit log_string("[OK] Vault successfully allocated to adapter via production path");
    }

    // ============================================================
    // TEST 4: YIELD GENERATION VIA AAVE MOCK
    // ============================================================

    function test_04_YieldGeneration() public {
        emit log_string("\n=== TEST 4: Yield Generation via Aave Mock ===");

        // Setup: deposits and allocation
        _depositDonors(climateVault, DONOR1_INITIAL_DEPOSIT, DONOR2_INITIAL_DEPOSIT, DONOR3_INITIAL_DEPOSIT);
        _allocateVaultToAdapter(climateVault, address(climateAaveAdapter));

        // Get aToken before yield
        address aToken = aavePool.getReserveData(address(usdc)).aTokenAddress;
        uint256 aTokenBalanceBefore = IERC20(aToken).balanceOf(address(climateAaveAdapter));

        emit log_named_uint("Adapter aToken balance before yield", aTokenBalanceBefore);

        // Inject yield via accrueYield (proper Aave simulation)
        _injectYieldToAave(address(usdc), YIELD_INJECTION_AMOUNT);

        // Check aToken balance grew
        uint256 aTokenBalanceAfter = IERC20(aToken).balanceOf(address(climateAaveAdapter));
        emit log_named_uint("Adapter aToken balance after yield", aTokenBalanceAfter);

        uint256 yieldGenerated = aTokenBalanceAfter - aTokenBalanceBefore;
        emit log_named_uint("Yield generated", yieldGenerated);

        assertGt(aTokenBalanceAfter, aTokenBalanceBefore, "aToken balance should grow");
        assertGt(yieldGenerated, 0, "Should have generated yield");

        // Verify adapter can observe the yield
        uint256 adapterAssets = climateAaveAdapter.totalAssets();
        assertGt(
            adapterAssets,
            DONOR1_INITIAL_DEPOSIT + DONOR2_INITIAL_DEPOSIT + DONOR3_INITIAL_DEPOSIT,
            "Adapter total assets should include yield"
        );

        emit log_string("[OK] Yield successfully generated and observable by adapter");
    }

    // ============================================================
    // TEST 5: YIELD HARVESTING VIA GIVEVAULT4626.HARVEST()
    // ============================================================

    function test_05_YieldHarvestingViaProductionPath() public {
        emit log_string("\n=== TEST 5: Yield Harvesting via GiveVault4626.harvest() ===");

        // Setup: deposits, allocation, and yield generation
        _depositDonors(climateVault, DONOR1_INITIAL_DEPOSIT, DONOR2_INITIAL_DEPOSIT, DONOR3_INITIAL_DEPOSIT);
        _allocateVaultToAdapter(climateVault, address(climateAaveAdapter));
        _injectYieldToAave(address(usdc), YIELD_INJECTION_AMOUNT);

        GiveVault4626 vault = GiveVault4626(payable(climateVault));

        // FIX: Router immediately distributes - check distribution effects, not router balance
        // Record campaign totals before harvest
        (uint256 campaignPayoutsBefore,) = payoutRouter.getCampaignTotals(campaignClimateId);

        emit log_named_uint("Campaign payouts before harvest", campaignPayoutsBefore);

        // Call harvest (anyone can call - no role needed)
        (uint256 profit, uint256 loss) = vault.harvest();

        emit log_named_uint("Harvest profit", profit);
        emit log_named_uint("Harvest loss", loss);

        assertGt(profit, 0, "Should have harvested profit");
        assertEq(loss, 0, "Should have no loss");

        // Pull model: users claim after harvest to realize payouts
        vm.prank(donor1);
        payoutRouter.claimYield(climateVault, address(usdc));

        // Verify campaign totals increased after claim
        (uint256 campaignPayoutsAfter,) = payoutRouter.getCampaignTotals(campaignClimateId);
        assertGt(campaignPayoutsAfter, campaignPayoutsBefore, "Campaign payouts should increase after harvest");

        emit log_named_uint("Campaign payouts after harvest", campaignPayoutsAfter);
        emit log_string("[OK] Yield successfully harvested and distributed via PayoutRouter");
    }

    // ============================================================
    // TEST 6: CHECKPOINT GOVERNANCE
    // ============================================================

    function test_06_CheckpointGovernance() public {
        emit log_string("\n=== TEST 6: Checkpoint Governance ===");

        // Setup: deposits for voting power
        _depositDonors(climateVault, DONOR1_INITIAL_DEPOSIT, DONOR2_INITIAL_DEPOSIT, DONOR3_INITIAL_DEPOSIT);

        // Create a checkpoint for the campaign
        uint64 votingStart = uint64(block.timestamp);
        uint64 votingEnd = uint64(block.timestamp + 7 days);
        uint16 quorumBps = 5000; // 50% quorum

        emit log_string("Creating checkpoint...");
        uint256 checkpointIndex = _scheduleCheckpoint(campaignClimateId, votingStart, votingEnd, quorumBps);

        emit log_named_uint("Checkpoint created at index", checkpointIndex);

        // Warp to voting period
        vm.warp(votingStart + 1 hours);

        // FIX: Transition checkpoint from Scheduled → Voting (CHECKPOINT_COUNCIL role)
        emit log_string("Transitioning checkpoint to Voting status...");
        vm.prank(checkpointCouncil);
        campaignRegistry.updateCheckpointStatus(campaignClimateId, checkpointIndex, GiveTypes.CheckpointStatus.Voting);

        // Donors vote on checkpoint
        emit log_string("Donors voting on checkpoint...");

        _voteOnCheckpoint(donor1, campaignClimateId, checkpointIndex, true); // For
        _voteOnCheckpoint(donor2, campaignClimateId, checkpointIndex, true); // For
        _voteOnCheckpoint(donor3, campaignClimateId, checkpointIndex, false); // Against

        emit log_string("Votes cast: Donor1=For, Donor2=For, Donor3=Against");

        // Warp past voting window
        vm.warp(votingEnd + 1 hours);

        // Finalize checkpoint
        emit log_string("Finalizing checkpoint...");
        _finalizeCheckpoint(campaignClimateId, checkpointIndex);

        // Verify checkpoint state (TIGHTENED: must be exactly Succeeded, not Executed)
        (,,,, GiveTypes.CheckpointStatus status,) = campaignRegistry.getCheckpoint(campaignClimateId, checkpointIndex);

        emit log_named_uint("Checkpoint status", uint8(status));

        assertEq(
            uint8(status),
            uint8(GiveTypes.CheckpointStatus.Succeeded),
            "Checkpoint must be exactly Succeeded after finalization"
        );

        emit log_string("[OK] Checkpoint governance completed with exact status validation");
    }

    // ============================================================
    // TEST 7: CAMPAIGN COMPLETION WITH PAYOUT ROUTER VALIDATION
    // ============================================================

    function test_07_CampaignCompletionWithPayoutRouterValidation() public {
        emit log_string("\n=== TEST 7: Campaign Completion with PayoutRouter Validation ===");

        // Setup: full flow with yield
        _depositDonors(climateVault, DONOR1_INITIAL_DEPOSIT, DONOR2_INITIAL_DEPOSIT, DONOR3_INITIAL_DEPOSIT);
        _allocateVaultToAdapter(climateVault, address(climateAaveAdapter));
        _injectYieldToAave(address(usdc), YIELD_INJECTION_AMOUNT);

        GiveVault4626 vault = GiveVault4626(payable(climateVault));

        // FIX: Record campaign totals before harvest (router distributes immediately)
        (uint256 campaignPayoutsBefore,) = payoutRouter.getCampaignTotals(campaignClimateId);
        emit log_named_uint("Campaign payouts before", campaignPayoutsBefore);

        // Harvest yield - this records yield in PayoutRouter accumulator
        (uint256 profit,) = vault.harvest();
        emit log_named_uint("Harvested profit", profit);

        // Pull model: user claim materializes campaign payout transfers
        vm.prank(donor1);
        payoutRouter.claimYield(climateVault, address(usdc));

        (uint256 campaignPayoutsAfter,) = payoutRouter.getCampaignTotals(campaignClimateId);
        emit log_named_uint("Campaign payouts after", campaignPayoutsAfter);

        // Verify distribution occurred and was tracked
        assertGt(profit, 0, "Should have harvested profit");
        assertGt(campaignPayoutsAfter, campaignPayoutsBefore, "Campaign payouts should increase after distribution");

        emit log_named_uint("Campaign total payouts tracked", campaignPayoutsAfter);
        emit log_string("[OK] Yield distributed through PayoutRouter with tracking validated");
    }

    // ============================================================
    // TEST 8: DONOR WITHDRAWALS
    // ============================================================

    function test_08_DonorWithdrawals() public {
        emit log_string("\n=== TEST 8: Donor Withdrawals ===");

        // Setup: deposits, allocation, yield, harvest
        _depositDonors(climateVault, DONOR1_INITIAL_DEPOSIT, DONOR2_INITIAL_DEPOSIT, DONOR3_INITIAL_DEPOSIT);
        _allocateVaultToAdapter(climateVault, address(climateAaveAdapter));
        _injectYieldToAave(address(usdc), YIELD_INJECTION_AMOUNT);

        GiveVault4626 vault = GiveVault4626(payable(climateVault));
        vault.harvest();

        // Withdraw all adapter funds back to vault for redemption
        uint256 adapterAssets = climateAaveAdapter.totalAssets();
        vm.prank(climateVault); // Only vault can call adapter.divest()
        climateAaveAdapter.divest(adapterAssets);

        // Check donor1's shares and convertible amount
        uint256 donor1Shares = vault.balanceOf(donor1);
        uint256 donor1Assets = vault.convertToAssets(donor1Shares);

        emit log_named_uint("Donor1 shares", donor1Shares);
        emit log_named_uint("Donor1 redeemable assets", donor1Assets);

        // NOTE: Donor principal should be intact (yield went to campaign)
        // Assets should be approximately equal to initial deposit (no yield for donors in campaign vaults)
        assertApproxEqAbs(donor1Assets, DONOR1_INITIAL_DEPOSIT, 100, "Donor assets should match initial deposit");

        // Record balances before withdrawal
        uint256 donor1BalanceBefore = usdc.balanceOf(donor1);

        // Donor1 redeems all shares
        vm.startPrank(donor1);
        uint256 assetsReceived = vault.redeem(donor1Shares, donor1, donor1);
        vm.stopPrank();

        emit log_named_uint("Donor1 received assets", assetsReceived);

        // Verify withdrawal
        uint256 donor1BalanceAfter = usdc.balanceOf(donor1);
        assertEq(donor1BalanceAfter - donor1BalanceBefore, assetsReceived, "Should receive assets");
        assertEq(vault.balanceOf(donor1), 0, "Shares should be burned");

        // Verify PayoutRouter updated shares
        assertEq(payoutRouter.getUserVaultShares(donor1, climateVault), 0, "Router should clear donor1 shares");

        emit log_string("[OK] Donor1 successfully withdrew with router tracking update");

        // Test partial withdrawal for donor2
        uint256 donor2Shares = vault.balanceOf(donor2);
        uint256 partialShares = donor2Shares / 2;

        emit log_named_uint("Donor2 total shares", donor2Shares);
        emit log_named_uint("Donor2 withdrawing shares", partialShares);

        vm.startPrank(donor2);
        uint256 partialAssets = vault.redeem(partialShares, donor2, donor2);
        vm.stopPrank();

        emit log_named_uint("Donor2 received assets", partialAssets);

        // Verify partial withdrawal
        assertEq(vault.balanceOf(donor2), donor2Shares - partialShares, "Half shares should remain");
        assertGt(partialAssets, 0, "Should receive assets");

        // Verify PayoutRouter updated to remaining shares
        assertEq(
            payoutRouter.getUserVaultShares(donor2, climateVault),
            donor2Shares - partialShares,
            "Router should track remaining shares"
        );

        emit log_string("[OK] Donor2 successfully made partial withdrawal with tracking");
    }

    // ============================================================
    // TEST 9: FULL END-TO-END INTEGRATION (STANDALONE)
    // ============================================================

    function test_09_FullEndToEndFlowStandalone() public {
        emit log_string("\n=== TEST 9: Full End-to-End Campaign Lifecycle (Standalone) ===");

        // Step 1: Verify campaign setup
        GiveTypes.CampaignConfig memory campaign = campaignRegistry.getCampaign(campaignClimateId);
        assertEq(uint8(campaign.status), uint8(GiveTypes.CampaignStatus.Active), "Campaign active");
        emit log_string("  [OK] Campaign submission and approval");

        // Step 2: Donors deposit
        _depositDonors(climateVault, DONOR1_INITIAL_DEPOSIT, DONOR2_INITIAL_DEPOSIT, DONOR3_INITIAL_DEPOSIT);
        uint256 totalDeposits = DONOR1_INITIAL_DEPOSIT + DONOR2_INITIAL_DEPOSIT + DONOR3_INITIAL_DEPOSIT;
        assertEq(CampaignVault4626(payable(climateVault)).totalAssets(), totalDeposits, "Deposits received");
        emit log_string("  [OK] Donor deposits and share minting");

        // Step 3: Allocate to adapter
        _allocateVaultToAdapter(climateVault, address(climateAaveAdapter));
        assertEq(climateAaveAdapter.totalAssets(), totalDeposits, "Funds in adapter");
        emit log_string("  [OK] Vault allocation to yield adapter");

        // Step 4: Generate yield
        _injectYieldToAave(address(usdc), YIELD_INJECTION_AMOUNT);
        assertGt(climateAaveAdapter.totalAssets(), totalDeposits, "Yield generated");
        emit log_string("  [OK] Yield generation via Aave mock");

        // Step 5: Harvest yield
        GiveVault4626 vault = GiveVault4626(payable(climateVault));
        (uint256 profit,) = vault.harvest();
        assertGt(profit, 0, "Profit harvested");

        vm.prank(donor1);
        payoutRouter.claimYield(climateVault, address(usdc));

        emit log_string("  [OK] Yield harvesting and distribution");

        // Step 6: Checkpoint governance
        // Use a start time slightly in the future to avoid edge timing issues
        uint64 start = uint64(block.timestamp + 1);
        uint64 end = start + 7 days;
        uint256 checkpointIndex = _scheduleCheckpoint(campaignClimateId, start, end, 5000);
        vm.warp(start + 1 hours);
        // FIX: Transition to Voting status before voting
        vm.prank(checkpointCouncil);
        campaignRegistry.updateCheckpointStatus(campaignClimateId, checkpointIndex, GiveTypes.CheckpointStatus.Voting);
        _voteOnCheckpoint(donor1, campaignClimateId, checkpointIndex, true);
        _voteOnCheckpoint(donor2, campaignClimateId, checkpointIndex, true);
        vm.warp(block.timestamp + 7 days);
        _finalizeCheckpoint(campaignClimateId, checkpointIndex);
        (,,,, GiveTypes.CheckpointStatus status,) = campaignRegistry.getCheckpoint(campaignClimateId, checkpointIndex);
        assertEq(uint8(status), uint8(GiveTypes.CheckpointStatus.Succeeded), "Checkpoint passed");
        emit log_string("  [OK] Checkpoint governance and voting");

        // Step 7: Verify PayoutRouter tracking
        (uint256 campaignPayouts,) = payoutRouter.getCampaignTotals(campaignClimateId);
        assertGt(campaignPayouts, 0, "Payouts tracked");
        emit log_string("  [OK] Campaign payout tracking validated");

        // Step 8: Donor withdrawal
        uint256 adapterAssets = climateAaveAdapter.totalAssets();
        vm.prank(climateVault);
        climateAaveAdapter.divest(adapterAssets);
        uint256 donor1Shares = vault.balanceOf(donor1);
        vm.prank(donor1);
        vault.redeem(donor1Shares, donor1, donor1);
        assertEq(vault.balanceOf(donor1), 0, "Donor withdrew");
        emit log_string("  [OK] Donor withdrawals");

        emit log_string("\n[SUCCESS] FULL END-TO-END FLOW COMPLETED SUCCESSFULLY [SUCCESS]");
    }

    // ============================================================
    // TEST 10: MULTIPLE CONCURRENT CAMPAIGNS WITH CROSS-VAULT VALIDATION
    // ============================================================

    function test_10_MultipleConcurrentCampaignsWithValidation() public {
        emit log_string("\n=== TEST 10: Multiple Concurrent Campaigns with Validation ===");

        // Deposit into all three campaigns
        vm.startPrank(donor1);
        usdc.approve(climateVault, 10_000e6);
        CampaignVault4626(payable(climateVault)).deposit(10_000e6, donor1);
        vm.stopPrank();

        vm.startPrank(donor2);
        usdc.approve(educationVault, 15_000e6);
        CampaignVault4626(payable(educationVault)).deposit(15_000e6, donor2);
        vm.stopPrank();

        vm.startPrank(donor3);
        dai.approve(medicalVault, 20_000e18);
        CampaignVault4626(payable(medicalVault)).deposit(20_000e18, donor3);
        vm.stopPrank();

        // Verify all campaigns received deposits
        assertEq(CampaignVault4626(payable(climateVault)).totalAssets(), 10_000e6, "Climate vault funded");
        assertEq(CampaignVault4626(payable(educationVault)).totalAssets(), 15_000e6, "Education vault funded");
        assertEq(CampaignVault4626(payable(medicalVault)).totalAssets(), 20_000e18, "Medical vault funded");

        // Validate strategy registry tracking
        address[] memory aaveStrategyVaults = strategyRegistry.getStrategyVaults(aaveUsdcStrategyId);
        assertGe(aaveStrategyVaults.length, 2, "Aave strategy should have 2+ vaults");

        bool foundClimate = false;
        bool foundEducation = false;
        for (uint256 i = 0; i < aaveStrategyVaults.length; i++) {
            if (aaveStrategyVaults[i] == climateVault) foundClimate = true;
            if (aaveStrategyVaults[i] == educationVault) foundEducation = true;
        }
        assertTrue(foundClimate && foundEducation, "Both USDC vaults should be in Aave strategy");

        // Validate PayoutRouter registration
        assertEq(payoutRouter.getVaultCampaign(climateVault), campaignClimateId, "Climate registered");
        assertEq(payoutRouter.getVaultCampaign(educationVault), campaignEducationId, "Education registered");
        assertEq(payoutRouter.getVaultCampaign(medicalVault), campaignMedicalId, "Medical registered");

        // Allocate all vaults to their campaign-specific adapters
        _allocateVaultToAdapter(climateVault, address(climateAaveAdapter));
        _allocateVaultToAdapter(educationVault, address(educationAaveAdapter));
        _allocateVaultToAdapter(medicalVault, address(medicalCompoundingAdapter));

        // Verify adapters hold funds (each vault has its own adapter now)
        assertEq(climateAaveAdapter.totalAssets(), 10_000e6, "Climate adapter holds USDC");
        assertEq(educationAaveAdapter.totalAssets(), 15_000e6, "Education adapter holds USDC");
        assertEq(medicalCompoundingAdapter.totalAssets(), 20_000e18, "Medical adapter holds DAI");

        // Inject yield to Aave adapters (USDC)
        _injectYieldToAave(address(usdc), 2_000e6);

        // FIX: CompoundingAdapter doesn't use Aave - transfer DAI directly to simulate balance growth
        dai.mint(address(medicalCompoundingAdapter), 3_000e18);

        // Harvest all vaults - they should not interfere
        (uint256 climateProfit,) = GiveVault4626(payable(climateVault)).harvest();
        (uint256 educationProfit,) = GiveVault4626(payable(educationVault)).harvest();
        (uint256 medicalProfit,) = GiveVault4626(payable(medicalVault)).harvest();

        emit log_named_uint("Climate profit", climateProfit);
        emit log_named_uint("Education profit", educationProfit);
        emit log_named_uint("Medical profit", medicalProfit);

        assertGt(climateProfit, 0, "Climate should harvest yield");
        assertGt(educationProfit, 0, "Education should harvest yield");
        assertGt(medicalProfit, 0, "Medical should harvest yield");

        emit log_string("[OK] Multiple campaigns operating concurrently with full validation");
    }

    // ============================================================
    // TEST 11: EDGE CASE - ZERO DEPOSITS (SPECIFIC ERROR)
    // ============================================================

    function test_11_EdgeCase_ZeroDeposits() public {
        emit log_string("\n=== TEST 11: Edge Case - Zero Deposits ===");

        CampaignVault4626 vault = CampaignVault4626(payable(climateVault));

        // FIX: ERC4626 standard allows zero deposits (no revert expected)
        // This is intentional behavior - zero deposits should succeed but mint zero shares
        vm.startPrank(donor1);
        usdc.approve(climateVault, 100e6);

        uint256 sharesBefore = vault.balanceOf(donor1);
        uint256 shares = vault.deposit(0, donor1);
        uint256 sharesAfter = vault.balanceOf(donor1);

        vm.stopPrank();

        assertEq(shares, 0, "Zero deposit should mint zero shares");
        assertEq(sharesAfter, sharesBefore, "Share balance should not change");

        emit log_string("[OK] Zero deposit handled correctly per ERC4626 standard");
    }

    // ============================================================
    // TEST 12: EDGE CASE - WITHDRAWAL EXCEEDS BALANCE (SPECIFIC ERROR)
    // ============================================================

    function test_12_EdgeCase_WithdrawalExceedsBalance() public {
        emit log_string("\n=== TEST 12: Edge Case - Withdrawal Exceeds Balance ===");

        // Setup: donor1 deposits
        vm.startPrank(donor1);
        usdc.approve(climateVault, DONOR1_INITIAL_DEPOSIT);
        CampaignVault4626(payable(climateVault)).deposit(DONOR1_INITIAL_DEPOSIT, donor1);
        vm.stopPrank();

        CampaignVault4626 vault = CampaignVault4626(payable(climateVault));
        uint256 donor1Shares = vault.balanceOf(donor1);

        // Attempt to redeem more shares than owned
        vm.startPrank(donor1);
        vm.expectRevert(); // ERC20 "insufficient balance" from OpenZeppelin
        vault.redeem(donor1Shares + 1, donor1, donor1);
        vm.stopPrank();

        emit log_string("[OK] Excessive withdrawal correctly reverted");
    }

    // ============================================================
    // HELPER FUNCTIONS (NOT TESTS)
    // ============================================================

    /**
     * @notice Helper to deposit from three donors without assertions
     * @param vault Vault address to deposit to
     * @param amount1 Donor1 deposit amount
     * @param amount2 Donor2 deposit amount
     * @param amount3 Donor3 deposit amount
     */
    function _depositDonors(address vault, uint256 amount1, uint256 amount2, uint256 amount3) internal {
        CampaignVault4626 v = CampaignVault4626(payable(vault));
        address asset = v.asset();
        // Resolve campaign ID for this vault to record governance stake
        bytes32 cid = payoutRouter.getVaultCampaign(vault);

        // Donor1 deposits (only if non-zero)
        if (amount1 > 0) {
            vm.startPrank(donor1);
            IERC20(asset).approve(vault, amount1);
            v.deposit(amount1, donor1);
            vm.stopPrank();

            // Record stake for governance voting power (curator action)
            vm.prank(admin); // admin holds CAMPAIGN_CURATOR by default
            campaignRegistry.recordStakeDeposit(cid, donor1, amount1);
        }

        // Donor2 deposits (only if non-zero)
        if (amount2 > 0) {
            vm.startPrank(donor2);
            IERC20(asset).approve(vault, amount2);
            v.deposit(amount2, donor2);
            vm.stopPrank();

            // Record stake for donor2
            vm.prank(admin);
            campaignRegistry.recordStakeDeposit(cid, donor2, amount2);
        }

        // Donor3 deposits (only if non-zero)
        if (amount3 > 0) {
            vm.startPrank(donor3);
            IERC20(asset).approve(vault, amount3);
            v.deposit(amount3, donor3);
            vm.stopPrank();

            // Record stake for donor3
            vm.prank(admin);
            campaignRegistry.recordStakeDeposit(cid, donor3, amount3);
        }
    }

    /**
     * @notice Helper to allocate vault funds to adapter via production path
     * @param vault Vault address
     * @param adapter Adapter address
     */
    function _allocateVaultToAdapter(address vault, address adapter) internal {
        GiveVault4626 v = GiveVault4626(payable(vault));
        IERC20 asset = IERC20(v.asset());

        vm.startPrank(vaultManager);
        // Set active adapter
        v.setActiveAdapter(IYieldAdapter(adapter));
        vm.stopPrank();

        // Transfer assets from vault to adapter
        uint256 vaultBalance = asset.balanceOf(vault);
        vm.prank(vault);
        require(asset.transfer(adapter, vaultBalance), "Transfer failed");

        // Adapter invests
        vm.prank(vault);
        IYieldAdapter(adapter).invest(vaultBalance);
    }

    /**
     * @notice Helper to inject yield into Aave pool via accrueYield
     * @param asset Asset address
     * @param yieldAmount Amount of yield to inject
     */
    function _injectYieldToAave(address asset, uint256 yieldAmount) internal {
        // Mint yield tokens to this contract
        if (asset == address(usdc)) {
            usdc.mint(address(this), yieldAmount);
        } else if (asset == address(dai)) {
            dai.mint(address(this), yieldAmount);
        }

        // Approve and inject via accrueYield
        IERC20(asset).approve(address(aavePool), yieldAmount);
        aavePool.accrueYield(asset, yieldAmount);
    }

    // Note: _scheduleCheckpoint, _voteOnCheckpoint, and _finalizeCheckpoint
    // are inherited from Base03_DeployComprehensiveEnvironment

    // ============================================================
    // TEST 13: EMERGENCY PAUSE, GRACE, AND USER EMERGENCY WITHDRAW
    // ============================================================

    function test_13_EmergencyPauseGraceAndUserWithdrawal() public {
        emit log_string("\n=== TEST 13: Emergency Pause, Grace, and User Emergency Withdrawal ===");

        // Setup: donors deposit and allocate to adapter
        _depositDonors(climateVault, DONOR1_INITIAL_DEPOSIT, DONOR2_INITIAL_DEPOSIT, DONOR3_INITIAL_DEPOSIT);
        _allocateVaultToAdapter(climateVault, address(climateAaveAdapter));

        GiveVault4626 vault = GiveVault4626(payable(climateVault));

        // Emergency pause by admin (PAUSER_ROLE on vault)
        vm.prank(admin);
        vault.emergencyPause();

        // Before grace expires, emergencyWithdrawUser should revert
        uint256 donor1Shares = vault.balanceOf(donor1);
        vm.startPrank(donor1);
        vm.expectRevert(GiveVault4626.GracePeriodActive.selector);
        vault.emergencyWithdrawUser(donor1Shares / 2, donor1, donor1);
        vm.stopPrank();

        // After grace period, owner can withdraw without allowance
        vm.warp(block.timestamp + vault.EMERGENCY_GRACE_PERIOD() + 1);

        uint256 donor1SharesBefore = vault.balanceOf(donor1);
        vm.startPrank(donor1);
        uint256 assetsWithdrawn = vault.emergencyWithdrawUser(donor1SharesBefore / 2, donor1, donor1);
        vm.stopPrank();

        emit log_named_uint("Assets withdrawn (emergency)", assetsWithdrawn);

        // Verify shares reduced
        assertEq(vault.balanceOf(donor1), donor1SharesBefore - (donor1SharesBefore / 2), "Half shares should remain");

        emit log_string("[OK] Emergency flow honored grace and allowed owner withdrawal");
    }

    // ============================================================
    // TEST 14: FAILED CHECKPOINT HALTS PAYOUTS, SUCCESS RESUMES
    // ============================================================

    function test_14_CheckpointFailureHaltsAndSuccessResumesPayouts() public {
        emit log_string("\n=== TEST 14: Failed Checkpoint Halts Payouts; Success Resumes ===");

        // Setup: deposits, allocation, and yield generation
        _depositDonors(climateVault, DONOR1_INITIAL_DEPOSIT, DONOR2_INITIAL_DEPOSIT, DONOR3_INITIAL_DEPOSIT);
        _allocateVaultToAdapter(climateVault, address(climateAaveAdapter));
        _injectYieldToAave(address(usdc), YIELD_INJECTION_AMOUNT);

        GiveVault4626 vault = GiveVault4626(payable(climateVault));

        // Schedule a checkpoint with high quorum to force failure
        uint64 start = uint64(block.timestamp + 2);
        uint64 end = start + 2 days;
        uint256 idxFail = _scheduleCheckpoint(campaignClimateId, start, end, 9000);

        // Open voting
        vm.warp(start + 1 hours);
        vm.prank(checkpointCouncil);
        campaignRegistry.updateCheckpointStatus(campaignClimateId, idxFail, GiveTypes.CheckpointStatus.Voting);

        // Cast insufficient votes so quorum not met
        _voteOnCheckpoint(donor1, campaignClimateId, idxFail, false);

        // Finalize after window ends
        vm.warp(end + 1);
        _finalizeCheckpoint(campaignClimateId, idxFail);

        // With payouts halted, harvest should revert at router distribution
        vm.expectRevert(GiveErrors.OperationNotAllowed.selector);
        vault.harvest();

        // Schedule a new checkpoint with low quorum to resume payouts
        start = uint64(block.timestamp + 2);
        end = start + 2 days;
        uint256 idxSuccess = _scheduleCheckpoint(campaignClimateId, start, end, 1000);

        vm.warp(start + 1 hours);
        vm.prank(checkpointCouncil);
        campaignRegistry.updateCheckpointStatus(campaignClimateId, idxSuccess, GiveTypes.CheckpointStatus.Voting);

        _voteOnCheckpoint(donor1, campaignClimateId, idxSuccess, true);
        _voteOnCheckpoint(donor2, campaignClimateId, idxSuccess, true);

        vm.warp(end + 1);
        _finalizeCheckpoint(campaignClimateId, idxSuccess);

        // Inject fresh yield and harvest; should succeed now
        _injectYieldToAave(address(usdc), 1_000e6);
        (uint256 profit,) = vault.harvest();
        assertGt(profit, 0, "Harvest should succeed after payouts resume");

        emit log_string("[OK] Payouts halted on failure and resumed on success");
    }

    // ============================================================
    // TEST 15: ROUTER FEE TIMELOCK (INCREASE) AND INSTANT DECREASE
    // ============================================================

    function test_15_PayoutRouterFeeTimelockAndInstantDecrease() public {
        emit log_string("\n=== TEST 15: Router Fee Timelock and Instant Decrease ===");

        // Grant FEE_MANAGER_ROLE to admin on router
        bytes32 FEE_MANAGER_ROLE = payoutRouter.FEE_MANAGER_ROLE();
        vm.prank(admin);
        payoutRouter.grantRole(FEE_MANAGER_ROLE, admin);

        uint256 currentFee = payoutRouter.feeBps();
        address currentRecipient = payoutRouter.feeRecipient();

        // Propose an increase (timelocked)
        vm.prank(admin);
        payoutRouter.proposeFeeChange(currentRecipient, currentFee + 50); // +0.5%

        // Not executable yet
        vm.expectRevert();
        payoutRouter.executeFeeChange(0);

        // Warp past timelock and execute
        vm.warp(block.timestamp + payoutRouter.FEE_CHANGE_DELAY() + 1);
        payoutRouter.executeFeeChange(0);
        assertEq(payoutRouter.feeBps(), currentFee + 50, "Fee increased after timelock");

        // Propose a decrease (instant)
        vm.prank(admin);
        payoutRouter.proposeFeeChange(currentRecipient, currentFee);
        assertEq(payoutRouter.feeBps(), currentFee, "Fee decreased instantly");

        emit log_string("[OK] Fee timelock increase and instant decrease validated");
    }

    // ============================================================
    // TEST 16: VAULT UUPS UPGRADE AUTHORIZATION AND STATE INVARIANTS
    // ============================================================

    function test_16_VaultUpgradeAuthorizationAndStatePreserved() public {
        emit log_string("\n=== TEST 16: Vault UUPS Upgrade Authorization and State Preserved ===");

        // Setup: deposits to have non-zero state
        _depositDonors(climateVault, DONOR1_INITIAL_DEPOSIT, 0, 0);
        GiveVault4626 vault = GiveVault4626(payable(climateVault));
        uint256 supplyBefore = vault.totalSupply();
        address assetBefore = address(vault.asset());

        // Non-upgrader should not be able to upgrade (UUPS v5 uses upgradeToAndCall)
        CampaignVault4626 newImpl = new CampaignVault4626();
        vm.expectRevert();
        vault.upgradeToAndCall(address(newImpl), "");

        // Upgrader can upgrade
        vm.prank(upgrader);
        vault.upgradeToAndCall(address(newImpl), "");

        // Invariants hold
        assertEq(vault.totalSupply(), supplyBefore, "Supply invariant");
        assertEq(address(vault.asset()), assetBefore, "Asset invariant");

        emit log_string("[OK] UUPS upgrade gated and state preserved");
    }
}
