// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Base03_DeployComprehensiveEnvironment} from "../base/Base03_DeployComprehensiveEnvironment.t.sol";
import {GiveTypes} from "../../src/types/GiveTypes.sol";
import {CampaignVault4626} from "../../src/vault/CampaignVault4626.sol";
import {GiveVault4626} from "../../src/vault/GiveVault4626.sol";
import {MockYieldAdapter} from "../../src/mocks/MockYieldAdapter.sol";
import {StrategyManager} from "../../src/manager/StrategyManager.sol";
import {StrategyRegistry} from "../../src/registry/StrategyRegistry.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @title TestAction02_MultiStrategyOperations
 * @author GIVE Labs
 * @notice Integration tests for multi-strategy operations and adapter management
 * @dev Tests comprehensive strategy scenarios:
 *      1. Multiple adapters competing for vault capital
 *      2. Strategy switching and rebalancing
 *      3. Strategy lifecycle transitions (Active -> FadingOut -> Deprecated)
 *      4. Multi-campaign operations with different strategies
 *      5. Adapter approval and activation workflows
 *      6. Performance-based automatic rebalancing
 */
contract TestAction02_MultiStrategyOperations is Base03_DeployComprehensiveEnvironment {
    // ============================================================
    // TEST CONSTANTS
    // ============================================================

    uint256 constant DONOR_DEPOSIT = 100_000e6; // $100k USDC
    uint256 constant YIELD_AMOUNT = 5_000e6; // $5k yield

    // Additional adapters for testing
    MockYieldAdapter public alternativeAdapter;
    MockYieldAdapter public educationAlternativeAdapter;

    bytes32 public alternativeStrategyId;

    // Strategy managers for campaign vaults
    StrategyManager public climateStrategyManager;
    StrategyManager public educationStrategyManager;

    // Vault manager account
    address public vaultManager;

    // ============================================================
    // SETUP
    // ============================================================

    function setUp() public override {
        super.setUp(); // Deploy full Base03 environment

        // Create vault manager account
        vaultManager = makeAddr("vaultManager");

        // Deploy StrategyManagers for campaign vaults
        climateStrategyManager =
            new StrategyManager(address(climateVault), admin, address(strategyRegistry), address(campaignRegistry));

        educationStrategyManager =
            new StrategyManager(address(educationVault), admin, address(strategyRegistry), address(campaignRegistry));

        vm.startPrank(admin);
        bytes32 VAULT_MANAGER_ROLE = keccak256("VAULT_MANAGER_ROLE");
        if (!aclManager.roleExists(VAULT_MANAGER_ROLE)) {
            aclManager.createRole(VAULT_MANAGER_ROLE, admin);
        }
        aclManager.grantRole(VAULT_MANAGER_ROLE, vaultManager);
        aclManager.grantRole(VAULT_MANAGER_ROLE, admin);
        aclManager.grantRole(VAULT_MANAGER_ROLE, address(climateStrategyManager));
        aclManager.grantRole(VAULT_MANAGER_ROLE, address(educationStrategyManager));

        // Grant local vault manager roles to StrategyManager contracts
        CampaignVault4626(payable(climateVault))
            .grantRole(CampaignVault4626(payable(climateVault)).VAULT_MANAGER_ROLE(), address(climateStrategyManager));
        CampaignVault4626(payable(educationVault))
            .grantRole(
                CampaignVault4626(payable(educationVault)).VAULT_MANAGER_ROLE(), address(educationStrategyManager)
            );

        // Grant StrategyManager roles
        bytes32 STRATEGY_MANAGER_ROLE = climateStrategyManager.STRATEGY_MANAGER_ROLE();
        if (!aclManager.roleExists(STRATEGY_MANAGER_ROLE)) {
            aclManager.createRole(STRATEGY_MANAGER_ROLE, admin);
        }
        aclManager.grantRole(STRATEGY_MANAGER_ROLE, vaultManager);
        aclManager.grantRole(STRATEGY_MANAGER_ROLE, admin);
        climateStrategyManager.grantRole(STRATEGY_MANAGER_ROLE, vaultManager);
        climateStrategyManager.grantRole(STRATEGY_MANAGER_ROLE, admin);
        educationStrategyManager.grantRole(STRATEGY_MANAGER_ROLE, vaultManager);
        educationStrategyManager.grantRole(STRATEGY_MANAGER_ROLE, admin);

        bytes32 EMERGENCY_ROLE = climateStrategyManager.EMERGENCY_ROLE();
        if (!aclManager.roleExists(EMERGENCY_ROLE)) {
            aclManager.createRole(EMERGENCY_ROLE, admin);
        }
        aclManager.grantRole(EMERGENCY_ROLE, admin);
        climateStrategyManager.grantRole(EMERGENCY_ROLE, admin);
        educationStrategyManager.grantRole(EMERGENCY_ROLE, admin);
        vm.stopPrank();

        // Deploy additional adapters for testing
        vm.startPrank(admin);

        alternativeAdapter = new MockYieldAdapter(address(usdc), address(climateVault), address(aclManager));
        educationAlternativeAdapter = new MockYieldAdapter(address(usdc), address(educationVault), address(aclManager));

        vm.stopPrank();

        // Register alternative strategy
        alternativeStrategyId = keccak256("strategy.alternative.usdc");

        vm.startPrank(strategyAdmin);
        strategyRegistry.registerStrategy(
            StrategyRegistry.StrategyInput({
                id: alternativeStrategyId,
                adapter: address(alternativeAdapter),
                riskTier: keccak256("LOW"),
                maxTvl: 5_000_000e6,
                metadataHash: keccak256("ipfs://QmAlternative")
            })
        );
        vm.stopPrank();
    }

    // ============================================================
    // TEST 1: APPROVE AND ACTIVATE MULTIPLE ADAPTERS
    // ============================================================

    function test_01_ApproveMultipleAdaptersForVault() public {
        emit log_string("\n=== TEST 1: Approve Multiple Adapters ===");

        vm.startPrank(vaultManager);

        // Approve primary adapter (Aave)
        climateStrategyManager.setAdapterApproval(address(climateAaveAdapter), true);

        // Approve alternative adapter
        climateStrategyManager.setAdapterApproval(address(alternativeAdapter), true);

        vm.stopPrank();

        // Verify both adapters are approved
        address[] memory approved = climateStrategyManager.getApprovedAdapters();
        assertEq(approved.length, 2, "Should have 2 approved adapters");
        assertTrue(
            (approved[0] == address(climateAaveAdapter) && approved[1] == address(alternativeAdapter))
                || (approved[0] == address(alternativeAdapter) && approved[1] == address(climateAaveAdapter)),
            "Both adapters should be approved"
        );

        emit log_named_uint("Approved adapters count", approved.length);
    }

    // ============================================================
    // TEST 2: ACTIVATE ADAPTER AND DEPOSIT
    // ============================================================

    function test_02_ActivateAdapterAndDeposit() public {
        emit log_string("\n=== TEST 2: Activate Adapter and Deposit ===");

        // Approve and activate Aave adapter
        vm.startPrank(vaultManager);
        climateStrategyManager.setAdapterApproval(address(climateAaveAdapter), true);
        climateStrategyManager.setActiveAdapter(address(climateAaveAdapter));
        vm.stopPrank();

        // Mint USDC to donor
        vm.prank(admin);
        usdc.mint(donor1, DONOR_DEPOSIT);

        // Donor deposits
        vm.startPrank(donor1);
        usdc.approve(address(climateVault), DONOR_DEPOSIT);
        uint256 shares = CampaignVault4626(payable(climateVault)).deposit(DONOR_DEPOSIT, donor1);
        vm.stopPrank();

        emit log_named_uint("Shares minted", shares);
        emit log_named_uint("Vault total assets", CampaignVault4626(payable(climateVault)).totalAssets());

        // Verify vault allocated to adapter
        uint256 adapterBalance = climateAaveAdapter.totalAssets();
        emit log_named_uint("Adapter total assets", adapterBalance);

        assertTrue(adapterBalance > 0, "Adapter should have received funds");
        assertGt(shares, 0, "Should have minted shares");
    }

    // ============================================================
    // TEST 3: SWITCH ACTIVE ADAPTER (REBALANCING)
    // ============================================================

    function test_03_SwitchActiveAdapterRebalancing() public {
        emit log_string("\n=== TEST 3: Switch Active Adapter ===");

        // Setup: Approve both adapters
        vm.startPrank(vaultManager);
        climateStrategyManager.setAdapterApproval(address(climateAaveAdapter), true);
        climateStrategyManager.setAdapterApproval(address(alternativeAdapter), true);
        climateStrategyManager.setActiveAdapter(address(climateAaveAdapter));
        vm.stopPrank();

        // Deposit funds
        vm.prank(admin);
        usdc.mint(donor1, DONOR_DEPOSIT);

        vm.startPrank(donor1);
        usdc.approve(address(climateVault), DONOR_DEPOSIT);
        CampaignVault4626(payable(climateVault)).deposit(DONOR_DEPOSIT, donor1);
        vm.stopPrank();

        // Switch to alternative adapter
        vm.startPrank(vaultManager);
        climateStrategyManager.setActiveAdapter(address(alternativeAdapter));
        vm.stopPrank();

        // Verify active adapter switched (funds are not auto-migrated on switch)
        address active = address(CampaignVault4626(payable(climateVault)).activeAdapter());
        assertEq(active, address(alternativeAdapter), "Active adapter should switch to alternative");
    }

    // ============================================================
    // TEST 4: AUTOMATIC REBALANCING BASED ON PERFORMANCE
    // ============================================================

    function test_04_AutomaticRebalancingBasedOnPerformance() public {
        emit log_string("\n=== TEST 4: Automatic Rebalancing ===");

        // Setup: Approve both adapters and enable auto-rebalance
        vm.startPrank(vaultManager);
        climateStrategyManager.setAdapterApproval(address(climateAaveAdapter), true);
        climateStrategyManager.setAdapterApproval(address(alternativeAdapter), true);
        climateStrategyManager.setActiveAdapter(address(climateAaveAdapter));
        climateStrategyManager.setAutoRebalanceEnabled(true);
        climateStrategyManager.setRebalanceInterval(1 hours);
        vm.stopPrank();

        // Deposit funds
        vm.prank(admin);
        usdc.mint(donor1, DONOR_DEPOSIT);

        vm.startPrank(donor1);
        usdc.approve(address(climateVault), DONOR_DEPOSIT);
        CampaignVault4626(payable(climateVault)).deposit(DONOR_DEPOSIT, donor1);
        vm.stopPrank();

        // Simulate alternative adapter performing better by setting its reported totalAssets higher
        // MockYieldAdapter.totalAssets() is tracked via internal accounting, so set it directly as ACL admin
        uint256 aaveAssets = climateAaveAdapter.totalAssets();
        vm.prank(address(aclManager));
        alternativeAdapter.setTotalAssets(aaveAssets + YIELD_AMOUNT * 2);

        emit log_named_uint("Aave adapter total assets", climateAaveAdapter.totalAssets());
        emit log_named_uint("Alternative adapter total assets", alternativeAdapter.totalAssets());

        // Advance time past rebalance interval
        vm.warp(block.timestamp + 2 hours);

        // Trigger automatic rebalance (strategy manager compares adapters' totalAssets)
        vm.prank(vaultManager);
        climateStrategyManager.checkAndRebalance();

        address activeAdapter = address(CampaignVault4626(payable(climateVault)).activeAdapter());

        emit log_named_address("Active adapter after rebalance", activeAdapter);

        // Should have switched to the better-performing adapter
        assertEq(
            activeAdapter,
            address(alternativeAdapter),
            "Should have rebalanced to alternative adapter with higher total assets"
        );
    }

    // ============================================================
    // TEST 5: STRATEGY LIFECYCLE TRANSITION
    // ============================================================

    function test_05_StrategyLifecycleTransition() public {
        emit log_string("\n=== TEST 5: Strategy Lifecycle Transition ===");

        // Get strategy status
        GiveTypes.StrategyConfig memory strategyBefore = strategyRegistry.getStrategy(aaveUsdcStrategyId);
        assertEq(uint8(strategyBefore.status), uint8(GiveTypes.StrategyStatus.Active), "Strategy should start Active");

        // Transition to FadingOut
        vm.prank(strategyAdmin);
        strategyRegistry.setStrategyStatus(aaveUsdcStrategyId, GiveTypes.StrategyStatus.FadingOut);

        GiveTypes.StrategyConfig memory strategyFading = strategyRegistry.getStrategy(aaveUsdcStrategyId);
        assertEq(
            uint8(strategyFading.status), uint8(GiveTypes.StrategyStatus.FadingOut), "Strategy should be FadingOut"
        );

        emit log_string("Strategy transitioned to FadingOut");

        // During FadingOut, existing campaigns can still use it
        // but new campaigns should consider switching

        // Transition to Deprecated
        vm.prank(strategyAdmin);
        strategyRegistry.setStrategyStatus(aaveUsdcStrategyId, GiveTypes.StrategyStatus.Deprecated);

        GiveTypes.StrategyConfig memory strategyDeprecated = strategyRegistry.getStrategy(aaveUsdcStrategyId);
        assertEq(
            uint8(strategyDeprecated.status),
            uint8(GiveTypes.StrategyStatus.Deprecated),
            "Strategy should be Deprecated"
        );

        emit log_string("Strategy transitioned to Deprecated");

        // New campaigns cannot use deprecated strategies
        // (tested in CampaignRegistry tests)
    }

    // ============================================================
    // TEST 6: MULTI-CAMPAIGN CONCURRENT OPERATIONS
    // ============================================================

    function test_06_MultiCampaignConcurrentOperations() public {
        emit log_string("\n=== TEST 6: Multi-Campaign Concurrent Operations ===");

        // Setup adapters for both campaigns
        vm.startPrank(vaultManager);

        // Climate campaign - Aave adapter
        climateStrategyManager.setAdapterApproval(address(climateAaveAdapter), true);
        climateStrategyManager.setActiveAdapter(address(climateAaveAdapter));

        // Education campaign - Alternative adapter (separate adapter bound to educationVault)
        educationStrategyManager.setAdapterApproval(address(educationAlternativeAdapter), true);
        educationStrategyManager.setActiveAdapter(address(educationAlternativeAdapter));

        vm.stopPrank();

        // Mint USDC for donors
        vm.startPrank(admin);
        usdc.mint(donor1, DONOR_DEPOSIT);
        usdc.mint(donor2, DONOR_DEPOSIT);
        vm.stopPrank();

        // Donor1 deposits to climate campaign
        vm.startPrank(donor1);
        usdc.approve(address(climateVault), DONOR_DEPOSIT);
        uint256 climateShares = CampaignVault4626(payable(climateVault)).deposit(DONOR_DEPOSIT, donor1);
        vm.stopPrank();

        // Donor2 deposits to education campaign
        vm.startPrank(donor2);
        usdc.approve(address(educationVault), DONOR_DEPOSIT);
        uint256 educationShares = CampaignVault4626(payable(educationVault)).deposit(DONOR_DEPOSIT, donor2);
        vm.stopPrank();

        emit log_named_uint("Climate campaign shares", climateShares);
        emit log_named_uint("Education campaign shares", educationShares);

        // Verify both campaigns are operating independently
        uint256 climateInAdapter = climateAaveAdapter.totalAssets();
        uint256 educationInAdapter = educationAlternativeAdapter.totalAssets();

        emit log_named_uint("Climate campaign in Aave", climateInAdapter);
        emit log_named_uint("Education campaign in Alternative", educationInAdapter);

        assertGt(climateInAdapter, 0, "Climate should have funds in Aave");
        assertGt(educationInAdapter, 0, "Education should have funds in Alternative");

        // Verify no storage collision between campaigns
        (bytes32 climateCid,,,) = CampaignVault4626(payable(climateVault)).getCampaignMetadata();
        assertEq(climateCid, campaignClimateId, "Climate vault should track correct campaign");
        (bytes32 educationCid,,,) = CampaignVault4626(payable(educationVault)).getCampaignMetadata();
        assertEq(educationCid, campaignEducationId, "Education vault should track correct campaign");
    }

    // ============================================================
    // TEST 7: ADAPTER PERFORMANCE COMPARISON
    // ============================================================

    function test_07_AdapterPerformanceComparison() public {
        emit log_string("\n=== TEST 7: Adapter Performance Comparison ===");

        // Setup: Approve multiple adapters
        vm.startPrank(vaultManager);
        climateStrategyManager.setAdapterApproval(address(climateAaveAdapter), true);
        climateStrategyManager.setAdapterApproval(address(alternativeAdapter), true);
        climateStrategyManager.setActiveAdapter(address(climateAaveAdapter));
        vm.stopPrank();

        // Deposit to vault
        vm.prank(admin);
        usdc.mint(donor1, DONOR_DEPOSIT);

        vm.startPrank(donor1);
        usdc.approve(address(climateVault), DONOR_DEPOSIT);
        CampaignVault4626(payable(climateVault)).deposit(DONOR_DEPOSIT, donor1);
        vm.stopPrank();

        // Simulate different yield performance by setting mock's reported totalAssets
        uint256 aaveTotalAssets = climateAaveAdapter.totalAssets();
        vm.prank(address(aclManager));
        alternativeAdapter.setTotalAssets(aaveTotalAssets + (DONOR_DEPOSIT * 5) / 100);
        uint256 altTotalAssets = alternativeAdapter.totalAssets();

        emit log_named_uint("Aave total assets (with yield)", aaveTotalAssets);
        emit log_named_uint("Alternative total assets (with yield)", altTotalAssets);

        // Rebalancer should choose alternative (higher totalAssets)
        assertTrue(altTotalAssets > aaveTotalAssets, "Alternative should have higher total assets");

        // Manual rebalance
        vm.warp(block.timestamp + 2 hours);
        vm.prank(vaultManager);
        climateStrategyManager.rebalance();

        address activeAdapter = address(CampaignVault4626(payable(climateVault)).activeAdapter());
        assertEq(activeAdapter, address(alternativeAdapter), "Should have switched to better-performing adapter");
    }

    // ============================================================
    // TEST 8: MAX ADAPTERS ENFORCEMENT
    // ============================================================

    function test_08_MaxAdaptersEnforcement() public {
        emit log_string("\n=== TEST 8: Max Adapters Enforcement ===");

        vm.startPrank(vaultManager);

        // Approve adapters up to the limit (10)
        for (uint256 i = 0; i < 10; i++) {
            // Deploy mock adapter
            MockYieldAdapter adapter = new MockYieldAdapter(address(usdc), address(climateVault), address(aclManager));

            climateStrategyManager.setAdapterApproval(address(adapter), true);
        }

        // Verify we have 10 approved adapters
        address[] memory approved = climateStrategyManager.getApprovedAdapters();
        assertEq(approved.length, 10, "Should have exactly 10 approved adapters");

        // Attempt to add 11th adapter should revert
        MockYieldAdapter eleventhAdapter =
            new MockYieldAdapter(address(usdc), address(climateVault), address(aclManager));

        vm.expectRevert(); // Should revert with MaxAdaptersReached
        climateStrategyManager.setAdapterApproval(address(eleventhAdapter), true);

        vm.stopPrank();

        emit log_string("Max adapters limit enforced correctly");
    }

    // ============================================================
    // TEST 9: REVOKE ADAPTER APPROVAL
    // ============================================================

    function test_09_RevokeAdapterApproval() public {
        emit log_string("\n=== TEST 9: Revoke Adapter Approval ===");

        vm.startPrank(vaultManager);

        // Approve adapter
        climateStrategyManager.setAdapterApproval(address(climateAaveAdapter), true);

        // Verify approved
        address[] memory approvedBefore = climateStrategyManager.getApprovedAdapters();
        assertEq(approvedBefore.length, 1, "Should have 1 approved adapter");

        // Revoke approval
        climateStrategyManager.setAdapterApproval(address(climateAaveAdapter), false);

        // Verify revoked
        address[] memory approvedAfter = climateStrategyManager.getApprovedAdapters();
        assertEq(approvedAfter.length, 0, "Should have 0 approved adapters");

        vm.stopPrank();

        emit log_string("Adapter approval revoked successfully");
    }

    // ============================================================
    // TEST 10: STRATEGY REUSE ACROSS CAMPAIGNS
    // ============================================================

    function test_10_StrategyReuseAcrossCampaigns() public {
        emit log_string("\n=== TEST 10: Strategy Reuse Across Campaigns ===");

        // Both climate and education campaigns use aaveUsdcStrategyId
        GiveTypes.CampaignConfig memory climateCampaign = campaignRegistry.getCampaign(campaignClimateId);
        GiveTypes.CampaignConfig memory educationCampaign = campaignRegistry.getCampaign(campaignEducationId);

        assertEq(climateCampaign.strategyId, aaveUsdcStrategyId, "Climate should use Aave USDC strategy");
        assertEq(educationCampaign.strategyId, aaveUsdcStrategyId, "Education should use Aave USDC strategy");

        emit log_string("Same strategy ID used by both campaigns");

        // Verify strategy is registered with both vaults
        address[] memory strategyVaults = strategyRegistry.getStrategyVaults(aaveUsdcStrategyId);

        emit log_named_uint("Vaults using Aave USDC strategy", strategyVaults.length);

        // Should have at least 2 vaults (climate + education)
        assertGe(strategyVaults.length, 2, "Strategy should be used by multiple campaigns");

        emit log_string("Strategy successfully reused across multiple campaigns");
    }
}
