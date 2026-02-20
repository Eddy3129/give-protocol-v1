// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {StrategyManager} from "../src/manager/StrategyManager.sol";
import {ACLManager} from "../src/governance/ACLManager.sol";
import {StrategyRegistry} from "../src/registry/StrategyRegistry.sol";
import {CampaignRegistry} from "../src/registry/CampaignRegistry.sol";
import {MockERC20} from "../src/mocks/MockERC20.sol";
import {MockYieldAdapter} from "../src/mocks/MockYieldAdapter.sol";

/**
 * @title MockGiveVault
 * @notice Minimal mock vault for testing StrategyManager
 */
contract MockGiveVault {
    address public asset;
    address public activeAdapter;
    uint256 public cashBufferBps;
    uint256 public slippageBps;
    uint256 public maxLossBps;
    bool public investPaused;

    event ActiveAdapterChanged(address indexed oldAdapter, address indexed newAdapter);
    event VaultParametersUpdated(uint256 cashBufferBps, uint256 slippageBps, uint256 maxLossBps);
    event Paused();
    event Unpaused();

    constructor(address _asset) {
        asset = _asset;
        cashBufferBps = 1000; // 10%
        slippageBps = 100; // 1%
        maxLossBps = 50; // 0.5%
    }

    function setActiveAdapter(address adapter) external {
        emit ActiveAdapterChanged(activeAdapter, adapter);
        activeAdapter = adapter;
    }

    function totalAssets() external pure returns (uint256) {
        return 1000 ether;
    }

    function emergencyPause() external {
        investPaused = true;
    }

    function emergencyUnpause() external {
        investPaused = false;
    }

    function emergencyWithdrawFromAdapter() external returns (uint256) {
        return 100 ether; // Mock withdrawal amount
    }

    function setInvestPaused(bool _paused) external {
        investPaused = _paused;
    }

    function setCashBufferBps(uint256 _cashBufferBps) external {
        if (_cashBufferBps > 10_000) revert("cash buffer too high");
        cashBufferBps = _cashBufferBps;
    }

    function setSlippageBps(uint256 _slippageBps) external {
        if (_slippageBps > 1_000) revert("slippage too high");
        slippageBps = _slippageBps;
    }

    function setMaxLossBps(uint256 _maxLossBps) external {
        if (_maxLossBps > 500) revert("max loss too high");
        maxLossBps = _maxLossBps;
    }

    function approveAdapter(address adapter, uint256 amount) external {
        IERC20(asset).approve(adapter, amount);
    }
}

/**
 * @title TestContract09_StrategyManager
 * @notice Comprehensive test suite for StrategyManager adapter and parameter management
 * @dev Tests adapter approval, rebalancing, emergency controls, and access control
 */
contract TestContract09_StrategyManager is Test {
    StrategyManager public strategyManager;
    ACLManager public aclManager;
    StrategyRegistry public strategyRegistry;
    CampaignRegistry public campaignRegistry;
    MockGiveVault public vault;
    MockERC20 public usdc;
    MockYieldAdapter public adapter1;
    MockYieldAdapter public adapter2;
    MockYieldAdapter public adapter3;

    address public admin;
    address public adapterAdmin;
    address public rebalancer;
    address public emergency;
    address public user1;
    address public user2;

    bytes32 public strategyId;
    bytes32 public campaignId;

    function _seedAdapter(MockYieldAdapter adapter, uint256 amount) internal {
        usdc.mint(address(vault), amount);
        vault.approveAdapter(address(adapter), type(uint256).max);
        vm.prank(address(vault));
        adapter.invest(amount);
    }

    function setUp() public {
        // Create test addresses
        admin = makeAddr("admin");
        adapterAdmin = makeAddr("adapterAdmin");
        rebalancer = makeAddr("rebalancer");
        emergency = makeAddr("emergency");
        user1 = makeAddr("user1");
        user2 = makeAddr("user2");

        // Fund addresses
        vm.deal(admin, 100 ether);
        vm.deal(adapterAdmin, 100 ether);
        vm.deal(rebalancer, 100 ether);
        vm.deal(emergency, 100 ether);

        // Deploy mock asset
        usdc = new MockERC20("USD Coin", "USDC", 6);

        // Deploy ACL Manager
        aclManager = new ACLManager();
        aclManager.initialize(admin, makeAddr("upgrader"));

        // Deploy registries (we'll use mock implementations for testing)
        strategyRegistry = new StrategyRegistry();
        campaignRegistry = new CampaignRegistry();

        // Initialize registries
        vm.startPrank(admin);
        strategyRegistry.initialize(address(aclManager));
        campaignRegistry.initialize(admin, address(aclManager));
        vm.stopPrank();

        // Deploy mock vault
        vault = new MockGiveVault(address(usdc));

        // Deploy adapters
        adapter1 = new MockYieldAdapter(address(usdc), address(vault), admin);
        adapter2 = new MockYieldAdapter(address(usdc), address(vault), admin);
        adapter3 = new MockYieldAdapter(address(usdc), address(vault), admin);

        // Deploy StrategyManager (pass admin as _admin parameter so admin owns DEFAULT_ADMIN_ROLE)
        strategyManager =
            new StrategyManager(address(vault), admin, address(strategyRegistry), address(campaignRegistry));

        // Grant additional roles (constructor already grants DEFAULT_ADMIN_ROLE and STRATEGY_MANAGER_ROLE to admin)
        vm.startPrank(admin);
        strategyManager.grantRole(strategyManager.STRATEGY_MANAGER_ROLE(), adapterAdmin);
        strategyManager.grantRole(strategyManager.STRATEGY_MANAGER_ROLE(), rebalancer);
        strategyManager.grantRole(strategyManager.EMERGENCY_ROLE(), emergency);
        vm.stopPrank();

        // Create test identifiers
        strategyId = keccak256("test-strategy");
        campaignId = keccak256("test-campaign");
    }

    // ============================================
    // INITIALIZATION TESTS
    // ============================================

    function test_Contract09_Case01_initialization() public view {
        assertEq(address(strategyManager.vault()), address(vault));
        assertEq(strategyManager.rebalanceInterval(), 24 hours);
        assertTrue(strategyManager.autoRebalanceEnabled());
        assertFalse(strategyManager.emergencyMode());
    }

    function test_Contract09_Case02_constants() public view {
        assertEq(strategyManager.BASIS_POINTS(), 10000);
        assertEq(strategyManager.MAX_ADAPTERS(), 10);
        assertEq(strategyManager.MIN_REBALANCE_INTERVAL(), 1 hours);
        assertEq(strategyManager.MAX_REBALANCE_INTERVAL(), 30 days);
    }

    // ============================================
    // ADAPTER APPROVAL TESTS
    // ============================================

    function test_Contract09_Case03_setAdapterApproval() public {
        vm.prank(adapterAdmin);
        vm.expectEmit(true, false, false, true);
        emit StrategyManager.AdapterApproved(address(adapter1), true);
        strategyManager.setAdapterApproval(address(adapter1), true);

        assertTrue(strategyManager.approvedAdapters(address(adapter1)));
    }

    function test_Contract09_Case04_setAdapterApprovalUnauthorized() public {
        vm.prank(user1);
        vm.expectRevert();
        strategyManager.setAdapterApproval(address(adapter1), true);
    }

    function test_Contract09_Case05_approveMultipleAdapters() public {
        vm.startPrank(adapterAdmin);
        strategyManager.setAdapterApproval(address(adapter1), true);
        strategyManager.setAdapterApproval(address(adapter2), true);
        strategyManager.setAdapterApproval(address(adapter3), true);
        vm.stopPrank();

        assertTrue(strategyManager.approvedAdapters(address(adapter1)));
        assertTrue(strategyManager.approvedAdapters(address(adapter2)));
        assertTrue(strategyManager.approvedAdapters(address(adapter3)));
    }

    function test_Contract09_Case06_revokeAdapterApproval() public {
        // First approve
        vm.startPrank(adapterAdmin);
        strategyManager.setAdapterApproval(address(adapter1), true);
        assertTrue(strategyManager.approvedAdapters(address(adapter1)));

        // Then revoke
        vm.expectEmit(true, false, false, true);
        emit StrategyManager.AdapterApproved(address(adapter1), false);
        strategyManager.setAdapterApproval(address(adapter1), false);
        vm.stopPrank();

        assertFalse(strategyManager.approvedAdapters(address(adapter1)));
    }

    function test_Contract09_Case07_maxAdaptersLimit() public {
        vm.startPrank(adapterAdmin);

        // Approve MAX_ADAPTERS (10) adapters
        for (uint256 i = 0; i < 10; i++) {
            MockYieldAdapter adapter = new MockYieldAdapter(address(usdc), address(vault), admin);
            strategyManager.setAdapterApproval(address(adapter), true);
        }

        // Trying to approve 11th adapter should revert
        MockYieldAdapter adapter11 = new MockYieldAdapter(address(usdc), address(vault), admin);

        vm.expectRevert();
        strategyManager.setAdapterApproval(address(adapter11), true);
        vm.stopPrank();
    }

    // ============================================
    // ACTIVE ADAPTER TESTS
    // ============================================

    function test_Contract09_Case08_setActiveAdapter() public {
        // First approve adapter
        vm.prank(adapterAdmin);
        strategyManager.setAdapterApproval(address(adapter1), true);

        // Then set as active
        vm.prank(adapterAdmin);
        vm.expectEmit(true, false, false, false);
        emit StrategyManager.AdapterActivated(address(adapter1));
        strategyManager.setActiveAdapter(address(adapter1));
    }

    function test_Contract09_Case09_setActiveAdapterNotApproved() public {
        // Try to set unapproved adapter as active
        vm.prank(adapterAdmin);
        vm.expectRevert();
        strategyManager.setActiveAdapter(address(adapter1));
    }

    function test_Contract09_Case10_setActiveAdapterUnauthorized() public {
        // Approve adapter
        vm.prank(adapterAdmin);
        strategyManager.setAdapterApproval(address(adapter1), true);

        // Try to set active without permission
        vm.prank(user1);
        vm.expectRevert();
        strategyManager.setActiveAdapter(address(adapter1));
    }

    function test_Contract09_Case11_changeActiveAdapter() public {
        // Approve both adapters
        vm.startPrank(adapterAdmin);
        strategyManager.setAdapterApproval(address(adapter1), true);
        strategyManager.setAdapterApproval(address(adapter2), true);

        // Set adapter1 as active
        strategyManager.setActiveAdapter(address(adapter1));

        // Change to adapter2
        vm.expectEmit(true, false, false, false);
        emit StrategyManager.AdapterActivated(address(adapter2));
        strategyManager.setActiveAdapter(address(adapter2));
        vm.stopPrank();
    }

    // ============================================
    // VAULT PARAMETER TESTS
    // ============================================

    function test_Contract09_Case12_updateVaultParameters() public {
        uint256 newCashBuffer = 2000; // 20%
        uint256 newSlippage = 200; // 2%
        uint256 newMaxLoss = 100; // 1%

        vm.prank(adapterAdmin);
        vm.expectEmit(false, false, false, true);
        emit StrategyManager.ParametersUpdated(newCashBuffer, newSlippage, newMaxLoss);
        strategyManager.updateVaultParameters(newCashBuffer, newSlippage, newMaxLoss);

        assertEq(vault.cashBufferBps(), newCashBuffer);
        assertEq(vault.slippageBps(), newSlippage);
        assertEq(vault.maxLossBps(), newMaxLoss);
    }

    function test_Contract09_Case13_updateVaultParametersInvalidCashBuffer() public {
        vm.prank(adapterAdmin);
        vm.expectRevert();
        strategyManager.updateVaultParameters(10001, 100, 50); // > 100%
    }

    function test_Contract09_Case14_updateVaultParametersInvalidSlippage() public {
        vm.prank(adapterAdmin);
        vm.expectRevert();
        strategyManager.updateVaultParameters(1000, 1001, 50); // > 10%
    }

    function test_Contract09_Case15_updateVaultParametersInvalidMaxLoss() public {
        vm.prank(adapterAdmin);
        vm.expectRevert();
        strategyManager.updateVaultParameters(1000, 100, 501); // > 5%
    }

    function test_Contract09_Case16_updateVaultParametersUnauthorized() public {
        vm.prank(user1);
        vm.expectRevert();
        strategyManager.updateVaultParameters(2000, 200, 100);
    }

    // ============================================
    // REBALANCE INTERVAL TESTS
    // ============================================

    function test_Contract09_Case17_setRebalanceInterval() public {
        uint256 newInterval = 12 hours;

        vm.prank(adapterAdmin);
        vm.expectEmit(true, false, false, true);
        emit StrategyManager.RebalanceIntervalUpdated(24 hours, newInterval);
        strategyManager.setRebalanceInterval(newInterval);

        assertEq(strategyManager.rebalanceInterval(), newInterval);
    }

    function test_Contract09_Case18_setRebalanceIntervalTooLow() public {
        vm.prank(adapterAdmin);
        vm.expectRevert();
        strategyManager.setRebalanceInterval(30 minutes); // < MIN_REBALANCE_INTERVAL
    }

    function test_Contract09_Case19_setRebalanceIntervalTooHigh() public {
        vm.prank(adapterAdmin);
        vm.expectRevert();
        strategyManager.setRebalanceInterval(31 days); // > MAX_REBALANCE_INTERVAL
    }

    function test_Contract09_Case20_setAutoRebalanceEnabled() public {
        vm.prank(adapterAdmin);
        vm.expectEmit(true, false, false, true);
        emit StrategyManager.AutoRebalanceToggled(false);
        strategyManager.setAutoRebalanceEnabled(false);

        assertFalse(strategyManager.autoRebalanceEnabled());

        // Turn it back on
        vm.prank(adapterAdmin);
        vm.expectEmit(true, false, false, true);
        emit StrategyManager.AutoRebalanceToggled(true);
        strategyManager.setAutoRebalanceEnabled(true);

        assertTrue(strategyManager.autoRebalanceEnabled());
    }

    // ============================================
    // REBALANCING TESTS
    // ============================================

    function test_Contract09_Case21_manualRebalance() public {
        // Setup: Approve two adapters and activate adapter1
        vm.startPrank(adapterAdmin);
        strategyManager.setAdapterApproval(address(adapter1), true);
        strategyManager.setAdapterApproval(address(adapter2), true);
        strategyManager.setActiveAdapter(address(adapter1));
        vm.stopPrank();

        // Fund adapters via vault interactions so totalAssets accounting updates
        _seedAdapter(adapter1, 500 ether);
        _seedAdapter(adapter2, 1500 ether);

        // Perform rebalance - should switch from adapter1 to adapter2
        vm.prank(rebalancer);
        vm.expectEmit(false, false, false, true);
        emit StrategyManager.StrategyRebalanced(address(adapter1), address(adapter2));
        strategyManager.rebalance();

        // Verify lastRebalanceTime was updated
        assertGt(strategyManager.lastRebalanceTime(), 0);
    }

    function test_Contract09_Case22_rebalanceUnauthorized() public {
        vm.prank(user1);
        vm.expectRevert();
        strategyManager.rebalance();
    }

    function test_Contract09_Case23_checkAndRebalance() public {
        // Setup: Approve two adapters and activate adapter1
        vm.startPrank(adapterAdmin);
        strategyManager.setAdapterApproval(address(adapter1), true);
        strategyManager.setAdapterApproval(address(adapter2), true);
        strategyManager.setActiveAdapter(address(adapter1));
        vm.stopPrank();

        _seedAdapter(adapter1, 500 ether);
        _seedAdapter(adapter2, 1500 ether);

        // Advance beyond interval so auto-rebalance can trigger
        vm.warp(block.timestamp + 25 hours);

        // Rebalance should switch to adapter2
        uint256 initialTime = strategyManager.lastRebalanceTime();
        vm.prank(rebalancer);
        strategyManager.checkAndRebalance();
        assertGt(strategyManager.lastRebalanceTime(), initialTime);

        // Immediately trying again should not rebalance (interval not elapsed)
        uint256 lastTime = strategyManager.lastRebalanceTime();
        vm.prank(rebalancer);
        strategyManager.checkAndRebalance();
        assertEq(strategyManager.lastRebalanceTime(), lastTime);
        assertEq(vault.activeAdapter(), address(adapter2));

        // Fast forward time
        vm.warp(block.timestamp + 25 hours);
    }

    function test_Contract09_Case24_checkAndRebalanceAutoDisabled() public {
        // Disable auto rebalance
        vm.prank(adapterAdmin);
        strategyManager.setAutoRebalanceEnabled(false);

        // checkAndRebalance should not rebalance when disabled
        uint256 lastTime = strategyManager.lastRebalanceTime();
        vm.prank(rebalancer);
        strategyManager.checkAndRebalance();
        assertEq(strategyManager.lastRebalanceTime(), lastTime);
    }

    // ============================================
    // EMERGENCY MODE TESTS
    // ============================================

    function test_Contract09_Case25_activateEmergencyMode() public {
        vm.prank(emergency);
        vm.expectEmit(false, false, false, true);
        emit StrategyManager.EmergencyModeActivated(true);
        strategyManager.activateEmergencyMode();

        assertTrue(strategyManager.emergencyMode());
        assertTrue(vault.investPaused());
    }

    function test_Contract09_Case26_activateEmergencyModeUnauthorized() public {
        vm.prank(user1);
        vm.expectRevert();
        strategyManager.activateEmergencyMode();
    }

    function test_Contract09_Case27_deactivateEmergencyMode() public {
        // First activate
        vm.prank(emergency);
        strategyManager.activateEmergencyMode();
        assertTrue(strategyManager.emergencyMode());

        // Then deactivate (requires DEFAULT_ADMIN_ROLE, not EMERGENCY_ROLE)
        vm.prank(admin);
        vm.expectEmit(false, false, false, true);
        emit StrategyManager.EmergencyModeActivated(false);
        strategyManager.deactivateEmergencyMode();

        assertFalse(strategyManager.emergencyMode());
    }

    function test_Contract09_Case28_emergencyWithdraw() public {
        // Setup: Approve and activate adapter
        vm.startPrank(adapterAdmin);
        strategyManager.setAdapterApproval(address(adapter1), true);
        strategyManager.setActiveAdapter(address(adapter1));
        vm.stopPrank();

        // Fund adapter
        usdc.mint(address(adapter1), 1000 ether);

        // Activate emergency mode
        vm.prank(emergency);
        strategyManager.activateEmergencyMode();

        // Perform emergency withdraw
        vm.prank(emergency);
        uint256 withdrawn = strategyManager.emergencyWithdraw();

        assertGt(withdrawn, 0);
    }

    function test_Contract09_Case29_emergencyWithdrawNotInEmergencyMode() public {
        uint256 before = strategyManager.lastRebalanceTime();
        vm.prank(emergency);
        uint256 withdrawn = strategyManager.emergencyWithdraw();
        assertGt(withdrawn, 0);
        assertEq(strategyManager.lastRebalanceTime(), before);
    }

    function test_Contract09_Case30_emergencyWithdrawUnauthorized() public {
        // Activate emergency mode
        vm.prank(emergency);
        strategyManager.activateEmergencyMode();

        // Try to withdraw without permission
        vm.prank(user1);
        vm.expectRevert();
        strategyManager.emergencyWithdraw();
    }

    // ============================================
    // PAUSE CONTROL TESTS
    // ============================================

    function test_Contract09_Case31_pauseVault() public {
        vm.prank(emergency);
        strategyManager.setInvestPaused(true);

        assertTrue(vault.investPaused());
    }

    function test_Contract09_Case32_unpauseVault() public {
        // First pause
        vm.prank(emergency);
        strategyManager.setInvestPaused(true);
        assertTrue(vault.investPaused());

        // Then unpause
        vm.prank(emergency);
        strategyManager.setInvestPaused(false);

        assertFalse(vault.investPaused());
    }

    function test_Contract09_Case33_pauseUnauthorized() public {
        vm.prank(user1);
        vm.expectRevert();
        strategyManager.setInvestPaused(true);
    }

    function test_Contract09_Case34_unpauseUnauthorized() public {
        // Pause first
        vm.prank(emergency);
        strategyManager.setInvestPaused(true);

        // Try to unpause without permission
        vm.prank(user1);
        vm.expectRevert();
        strategyManager.setInvestPaused(false);
    }

    // ============================================
    // VIEW FUNCTION TESTS
    // ============================================

    function test_Contract09_Case35_getApprovedAdapters() public {
        // Approve multiple adapters
        vm.startPrank(adapterAdmin);
        strategyManager.setAdapterApproval(address(adapter1), true);
        strategyManager.setAdapterApproval(address(adapter2), true);
        strategyManager.setAdapterApproval(address(adapter3), true);
        vm.stopPrank();

        address[] memory adapters = strategyManager.getApprovedAdapters();
        assertEq(adapters.length, 3);
        assertEq(adapters[0], address(adapter1));
        assertEq(adapters[1], address(adapter2));
        assertEq(adapters[2], address(adapter3));
    }

    function test_Contract09_Case36_getVaultConfiguration() public view {
        // Query vault configuration directly
        uint256 cashBufferBps = vault.cashBufferBps();
        uint256 slippageBps = vault.slippageBps();
        uint256 maxLossBps = vault.maxLossBps();

        assertEq(cashBufferBps, 1000); // Default 10%
        assertEq(slippageBps, 100); // Default 1%
        assertEq(maxLossBps, 50); // Default 0.5%
    }

    function test_Contract09_Case37_rebalanceTimingLogic() public {
        // Record initial timestamp (set during deployment)
        uint256 initialTime = strategyManager.lastRebalanceTime();

        // Setup two adapters so rebalancing actually happens
        vm.startPrank(adapterAdmin);
        strategyManager.setAdapterApproval(address(adapter1), true);
        strategyManager.setAdapterApproval(address(adapter2), true);
        strategyManager.setActiveAdapter(address(adapter1));
        vm.stopPrank();

        _seedAdapter(adapter1, 500 ether);
        _seedAdapter(adapter2, 1500 ether);

        vm.warp(1 hours);
        vm.prank(rebalancer);
        strategyManager.rebalance();

        // Should have a rebalance time now
        uint256 lastTime = strategyManager.lastRebalanceTime();
        assertGt(lastTime, initialTime);
        assertEq(vault.activeAdapter(), address(adapter2));

        // Fast forward past interval
        vm.warp(block.timestamp + 25 hours);

        // Should be able to rebalance again
        _seedAdapter(adapter1, 2000 ether);
        uint256 before = strategyManager.lastRebalanceTime();
        vm.prank(rebalancer);
        strategyManager.rebalance();
        assertGt(strategyManager.lastRebalanceTime(), before);
    }

    // ============================================
    // INTEGRATION TESTS
    // ============================================

    function test_Contract09_Case38_fullLifecycle() public {
        // 1. Approve adapters
        vm.startPrank(adapterAdmin);
        strategyManager.setAdapterApproval(address(adapter1), true);
        strategyManager.setAdapterApproval(address(adapter2), true);

        // 2. Set active adapter
        strategyManager.setActiveAdapter(address(adapter1));

        // 3. Update vault parameters
        strategyManager.updateVaultParameters(1500, 150, 75);

        // 4. Configure rebalance settings
        strategyManager.setRebalanceInterval(6 hours);
        vm.stopPrank();

        _seedAdapter(adapter1, 1000 ether);

        vm.prank(rebalancer);
        strategyManager.rebalance();

        // 6. Fast forward and auto-rebalance check
        vm.warp(block.timestamp + 31 hours);

        uint256 lastTime = strategyManager.lastRebalanceTime();
        _seedAdapter(adapter2, 1500 ether);
        vm.prank(rebalancer);
        strategyManager.checkAndRebalance();
        assertEq(vault.activeAdapter(), address(adapter2));

        // 7. Switch to adapter2
        _seedAdapter(adapter2, 500 ether);

        vm.prank(adapterAdmin);
        strategyManager.setActiveAdapter(address(adapter2));

        // 8. Emergency scenario
        vm.prank(emergency);
        strategyManager.activateEmergencyMode();

        assertTrue(strategyManager.emergencyMode());

        vm.prank(emergency);
        uint256 withdrawn = strategyManager.emergencyWithdraw();
        assertGt(withdrawn, 0);

        // 9. Deactivate emergency
        vm.prank(admin);
        strategyManager.deactivateEmergencyMode();

        assertFalse(strategyManager.emergencyMode());
    }

    function test_Contract09_Case39_stressTestMultipleRebalances() public {
        // Setup
        vm.startPrank(adapterAdmin);
        strategyManager.setAdapterApproval(address(adapter1), true);
        strategyManager.setActiveAdapter(address(adapter1));
        strategyManager.setRebalanceInterval(1 hours);
        vm.stopPrank();

        usdc.mint(address(adapter1), 1000 ether);

        // Perform 10 rebalances over time
        for (uint256 i = 0; i < 10; i++) {
            vm.warp(block.timestamp + 2 hours);

            vm.prank(rebalancer);
            strategyManager.rebalance();

            assertTrue(strategyManager.lastRebalanceTime() > 0);
        }
    }

    function test_Contract09_Case40_edgeCaseZeroActiveAdapter() public {
        // Try to rebalance with no active adapter
        vm.prank(rebalancer);
        strategyManager.rebalance();
    }
}
