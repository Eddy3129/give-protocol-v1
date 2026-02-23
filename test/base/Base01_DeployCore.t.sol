// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {ACLManager} from "../../src/governance/ACLManager.sol";
import {StrategyRegistry} from "../../src/registry/StrategyRegistry.sol";
import {CampaignRegistry} from "../../src/registry/CampaignRegistry.sol";
import {NGORegistry} from "../../src/donation/NGORegistry.sol";
import {PayoutRouter} from "../../src/payout/PayoutRouter.sol";
import {MockERC20} from "../../src/mocks/MockERC20.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

/**
 * @title Base01_DeployCore
 * @author GIVE Labs
 * @notice Base test contract for deploying core GIVE protocol infrastructure
 * @dev Provides real deployments of:
 *      - ACLManager with canonical roles
 *      - StrategyRegistry, CampaignRegistry, NGORegistry (UUPS proxies)
 *      - PayoutRouter
 *      - Basic test assets (USDC, DAI)
 *
 *      This establishes the foundation for all integration tests.
 *      Child contracts inherit these deployments and add vaults/adapters.
 */
contract Base01_DeployCore is Test {
    // ============================================================
    // GOVERNANCE & ACCESS CONTROL
    // ============================================================

    ACLManager public aclManager;

    // ============================================================
    // REGISTRIES (UUPS PROXIES)
    // ============================================================

    StrategyRegistry public strategyRegistry;
    CampaignRegistry public campaignRegistry;
    NGORegistry public ngoRegistry;

    // ============================================================
    // DONATION INFRASTRUCTURE
    // ============================================================

    PayoutRouter public payoutRouter;

    // ============================================================
    // TEST ASSETS
    // ============================================================

    MockERC20 public usdc;
    MockERC20 public dai;

    // ============================================================
    // TEST ACCOUNTS
    // ============================================================

    address public admin;
    address public upgrader;
    address public protocolAdmin;
    address public strategyAdmin;
    address public campaignAdmin;
    address public campaignCreator;
    address public checkpointCouncil;
    address public protocolTreasury;

    // Regular users
    address public donor1;
    address public donor2;
    address public donor3;
    address public ngo1;
    address public ngo2;

    // ============================================================
    // CANONICAL ROLE IDS
    // ============================================================

    bytes32 public constant ROLE_SUPER_ADMIN = keccak256("ROLE_SUPER_ADMIN");
    bytes32 public constant ROLE_UPGRADER = keccak256("ROLE_UPGRADER");
    bytes32 public constant ROLE_PROTOCOL_ADMIN = keccak256("ROLE_PROTOCOL_ADMIN");
    bytes32 public constant ROLE_STRATEGY_ADMIN = keccak256("ROLE_STRATEGY_ADMIN");
    bytes32 public constant ROLE_CAMPAIGN_ADMIN = keccak256("ROLE_CAMPAIGN_ADMIN");
    bytes32 public constant ROLE_CAMPAIGN_CREATOR = keccak256("ROLE_CAMPAIGN_CREATOR");
    bytes32 public constant ROLE_CHECKPOINT_COUNCIL = keccak256("ROLE_CHECKPOINT_COUNCIL");

    // ============================================================
    // SETUP
    // ============================================================

    function setUp() public virtual {
        // ========================================
        // STEP 1: Create Test Accounts
        // ========================================

        admin = makeAddr("admin");
        upgrader = makeAddr("upgrader");
        protocolAdmin = makeAddr("protocolAdmin");
        strategyAdmin = makeAddr("strategyAdmin");
        campaignAdmin = makeAddr("campaignAdmin");
        campaignCreator = makeAddr("campaignCreator");
        checkpointCouncil = makeAddr("checkpointCouncil");
        protocolTreasury = makeAddr("protocolTreasury");

        donor1 = makeAddr("donor1");
        donor2 = makeAddr("donor2");
        donor3 = makeAddr("donor3");
        ngo1 = makeAddr("ngo1");
        ngo2 = makeAddr("ngo2");

        // ========================================
        // STEP 2: Deploy ACLManager
        // ========================================

        ACLManager aclImpl = new ACLManager();
        bytes memory aclInitData = abi.encodeWithSelector(
            ACLManager.initialize.selector,
            admin, // initialSuperAdmin
            upgrader // upgrader
        );

        ERC1967Proxy aclProxy = new ERC1967Proxy(address(aclImpl), aclInitData);
        aclManager = ACLManager(address(aclProxy));

        emit log_named_address("ACLManager deployed at", address(aclManager));

        // ========================================
        // STEP 3: Grant Canonical Roles
        // ========================================

        vm.startPrank(admin);

        // Grant protocol roles
        aclManager.grantRole(ROLE_PROTOCOL_ADMIN, protocolAdmin);
        aclManager.grantRole(ROLE_STRATEGY_ADMIN, strategyAdmin);
        aclManager.grantRole(ROLE_CAMPAIGN_ADMIN, campaignAdmin);
        aclManager.grantRole(ROLE_CAMPAIGN_CREATOR, campaignCreator);
        aclManager.grantRole(ROLE_CHECKPOINT_COUNCIL, checkpointCouncil);

        vm.stopPrank();

        emit log_string("ACL roles configured");
        emit log_named_address("admin", admin);
        emit log_named_address("strategyAdmin", strategyAdmin);
        emit log_named_address("protocolAdmin", protocolAdmin);
        emit log_named_address("campaignAdmin", campaignAdmin);

        // ========================================
        // STEP 4: Deploy Test Assets
        // ========================================

        usdc = new MockERC20("USD Coin", "USDC", 6);
        dai = new MockERC20("Dai Stablecoin", "DAI", 18);

        emit log_named_address("USDC deployed at", address(usdc));
        emit log_named_address("DAI deployed at", address(dai));

        // ========================================
        // STEP 5: Deploy StrategyRegistry
        // ========================================

        StrategyRegistry strategyImpl = new StrategyRegistry();
        bytes memory strategyInitData =
            abi.encodeWithSelector(StrategyRegistry.initialize.selector, address(aclManager));

        ERC1967Proxy strategyProxy = new ERC1967Proxy(address(strategyImpl), strategyInitData);
        strategyRegistry = StrategyRegistry(address(strategyProxy));

        emit log_named_address("StrategyRegistry deployed at", address(strategyRegistry));

        // ========================================
        // STEP 6: Deploy CampaignRegistry
        // ========================================

        CampaignRegistry campaignImpl = new CampaignRegistry();
        bytes memory campaignInitData = abi.encodeWithSelector(
            CampaignRegistry.initialize.selector, address(aclManager), address(strategyRegistry)
        );

        ERC1967Proxy campaignProxy = new ERC1967Proxy(address(campaignImpl), campaignInitData);
        campaignRegistry = CampaignRegistry(payable(address(campaignProxy)));

        emit log_named_address("CampaignRegistry deployed at", address(campaignRegistry));

        // ========================================
        // STEP 7: Deploy NGORegistry
        // ========================================

        NGORegistry ngoImpl = new NGORegistry();
        bytes memory ngoInitData = abi.encodeWithSelector(NGORegistry.initialize.selector, address(aclManager));

        ERC1967Proxy ngoProxy = new ERC1967Proxy(address(ngoImpl), ngoInitData);
        ngoRegistry = NGORegistry(address(ngoProxy));

        emit log_named_address("NGORegistry deployed at", address(ngoRegistry));

        vm.prank(campaignAdmin);
        campaignRegistry.setNGORegistry(address(ngoRegistry));

        // ========================================
        // STEP 8: Deploy PayoutRouter
        // ========================================

        // Deploy PayoutRouter as UUPS proxy
        PayoutRouter payoutImpl = new PayoutRouter();
        bytes memory payoutInitData = abi.encodeWithSelector(
            PayoutRouter.initialize.selector,
            admin, // initialAdmin
            address(aclManager), // aclManager
            address(campaignRegistry), // campaignRegistry
            protocolTreasury, // feeRecipient (same as treasury initially)
            protocolTreasury, // protocolTreasury
            250 // feeBps (2.5% initial fee)
        );

        ERC1967Proxy payoutProxy = new ERC1967Proxy(address(payoutImpl), payoutInitData);
        payoutRouter = PayoutRouter(address(payoutProxy));

        emit log_named_address("PayoutRouter deployed at", address(payoutRouter));

        // ========================================
        // STEP 9: Fund Test Accounts
        // ========================================

        // Mint 1M USDC to each donor
        usdc.mint(donor1, 1_000_000e6);
        usdc.mint(donor2, 1_000_000e6);
        usdc.mint(donor3, 1_000_000e6);

        // Mint 1M DAI to each donor
        dai.mint(donor1, 1_000_000e18);
        dai.mint(donor2, 1_000_000e18);
        dai.mint(donor3, 1_000_000e18);

        // Fund campaign creators with ETH for deposits
        vm.deal(campaignCreator, 10 ether);
        vm.deal(donor1, 1 ether);

        emit log_string("Test accounts funded");
    }

    // ============================================================
    // VALIDATION HELPERS (INTERNAL TO AVOID AUTO-RUN)
    // ============================================================

    /**
     * @notice Validates ACLManager deployment and role configuration
     * @dev Internal to avoid running as standalone test
     */
    function _validateACLManager() internal view {
        // Verify super admin
        assertTrue(aclManager.hasRole(ROLE_SUPER_ADMIN, admin), "Admin should have SUPER_ADMIN role");
        assertTrue(aclManager.hasRole(ROLE_UPGRADER, upgrader), "Upgrader should have UPGRADER role");

        // Verify protocol roles
        assertTrue(
            aclManager.hasRole(ROLE_PROTOCOL_ADMIN, protocolAdmin), "ProtocolAdmin should have PROTOCOL_ADMIN role"
        );
        assertTrue(
            aclManager.hasRole(ROLE_STRATEGY_ADMIN, strategyAdmin), "StrategyAdmin should have STRATEGY_ADMIN role"
        );
        assertTrue(
            aclManager.hasRole(ROLE_CAMPAIGN_ADMIN, campaignAdmin), "CampaignAdmin should have CAMPAIGN_ADMIN role"
        );
    }

    /**
     * @notice Validates registries are deployed and initialized
     * @dev Internal to avoid running as standalone test
     */
    function _validateRegistries() internal view {
        // Strategy Registry
        assertTrue(address(strategyRegistry) != address(0), "StrategyRegistry should be deployed");
        assertEq(address(strategyRegistry.aclManager()), address(aclManager), "StrategyRegistry ACL mismatch");

        // Campaign Registry
        assertTrue(address(campaignRegistry) != address(0), "CampaignRegistry should be deployed");
        assertEq(address(campaignRegistry.aclManager()), address(aclManager), "CampaignRegistry ACL mismatch");
        assertEq(
            address(campaignRegistry.strategyRegistry()),
            address(strategyRegistry),
            "CampaignRegistry StrategyRegistry mismatch"
        );

        // NGO Registry
        assertTrue(address(ngoRegistry) != address(0), "NGORegistry should be deployed");
        assertEq(address(ngoRegistry.aclManager()), address(aclManager), "NGORegistry ACL mismatch");
    }

    /**
     * @notice Validates PayoutRouter deployment
     * @dev Internal to avoid running as standalone test
     */
    function _validatePayoutRouter() internal view virtual {
        assertTrue(address(payoutRouter) != address(0), "PayoutRouter should be deployed");
        assertEq(address(payoutRouter.aclManager()), address(aclManager), "PayoutRouter ACL mismatch");
        assertEq(
            address(payoutRouter.campaignRegistry()),
            address(campaignRegistry),
            "PayoutRouter CampaignRegistry mismatch"
        );
        assertEq(payoutRouter.protocolTreasury(), protocolTreasury, "PayoutRouter protocolTreasury mismatch");
    }

    /**
     * @notice Validates test asset balances
     * @dev Internal to avoid running as standalone test
     */
    function _validateTestAssets() internal view {
        assertEq(usdc.balanceOf(donor1), 1_000_000e6, "Donor1 USDC balance incorrect");
        assertEq(usdc.balanceOf(donor2), 1_000_000e6, "Donor2 USDC balance incorrect");
        assertEq(dai.balanceOf(donor1), 1_000_000e18, "Donor1 DAI balance incorrect");
        assertEq(donor1.balance, 1 ether, "Donor1 ETH balance incorrect");
    }
}
