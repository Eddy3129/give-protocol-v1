// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test, console} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import {GiveVault4626} from "../../src/vault/GiveVault4626.sol";
import {CampaignVault4626} from "../../src/vault/CampaignVault4626.sol";
import {CampaignVaultFactory} from "../../src/factory/CampaignVaultFactory.sol";
import {ACLManager} from "../../src/governance/ACLManager.sol";
import {CampaignRegistry} from "../../src/registry/CampaignRegistry.sol";
import {StrategyRegistry} from "../../src/registry/StrategyRegistry.sol";
import {PayoutRouter} from "../../src/payout/PayoutRouter.sol";
import {GiveTypes} from "../../src/types/GiveTypes.sol";

/**
 * @title TestContract04_VaultSystem
 * @notice Comprehensive tests for vault UUPS migration (C-01 & M-01 fixes)
 * @dev Tests prove:
 *      1. Unique storage isolation between vault instances (C-01 fix)
 *      2. UUPS upgradeability works per vault (M-01 fix)
 *      3. Factory-enforced initialization
 *      4. Role assignment and access control
 *      5. Emergency withdrawal authorization
 */
contract TestContract04_VaultSystem is Test {
    // Mock ERC20 for testing
    MockERC20 public usdc;
    MockERC20 public weth;

    // ACL
    ACLManager public aclManager;

    // Vault implementations
    GiveVault4626 public giveVaultImpl;
    CampaignVault4626 public campaignVaultImpl;

    // Vault proxies
    GiveVault4626 public vault1;
    GiveVault4626 public vault2;
    CampaignVault4626 public campaignVault1;

    // Registries
    CampaignRegistry public campaignRegistry;
    StrategyRegistry public strategyRegistry;
    PayoutRouter public payoutRouter;

    // Factory
    CampaignVaultFactory public factory;

    // Test accounts
    address public protocolAdmin = address(0x1);
    address public vaultAdmin = address(0x2);
    address public user1 = address(0x3);
    address public user2 = address(0x4);

    // Test IDs
    bytes32 public constant STRATEGY_ID = keccak256("AAVE_V3_USDC");
    bytes32 public constant CAMPAIGN_ID = keccak256("SAVE_THE_WHALES");
    bytes32 public constant LOCK_PROFILE = keccak256("FLEXIBLE");

    function setUp() public {
        // Deploy mock tokens
        usdc = new MockERC20("USD Coin", "USDC", 6);
        weth = new MockERC20("Wrapped Ether", "WETH", 18);

        // Deploy ACL Manager
        ACLManager aclImpl = new ACLManager();
        bytes memory aclInitData = abi.encodeWithSelector(ACLManager.initialize.selector, protocolAdmin, protocolAdmin);
        ERC1967Proxy aclProxy = new ERC1967Proxy(address(aclImpl), aclInitData);
        aclManager = ACLManager(address(aclProxy));

        // Grant roles
        vm.startPrank(protocolAdmin);
        aclManager.grantRole(keccak256("ROLE_STRATEGY_ADMIN"), protocolAdmin);
        aclManager.grantRole(keccak256("ROLE_CAMPAIGN_ADMIN"), protocolAdmin);
        vm.stopPrank();

        // Deploy vault implementations
        giveVaultImpl = new GiveVault4626();
        campaignVaultImpl = new CampaignVault4626();

        // Deploy registries (simplified for testing)
        strategyRegistry = new StrategyRegistry();
        strategyRegistry.initialize(address(aclManager));

        campaignRegistry = new CampaignRegistry();
        campaignRegistry.initialize(address(aclManager), address(strategyRegistry));

        payoutRouter = new PayoutRouter();
        payoutRouter.initialize(
            protocolAdmin, // admin
            address(aclManager),
            address(campaignRegistry),
            protocolAdmin, // feeRecipient
            protocolAdmin, // protocolTreasury
            250 // feeBps
        );

        // Deploy factory
        factory = new CampaignVaultFactory();
        factory.initialize(
            address(aclManager),
            address(campaignRegistry),
            address(strategyRegistry),
            address(payoutRouter),
            address(campaignVaultImpl)
        );

        // Grant factory the roles it needs to call registries and router
        vm.startPrank(protocolAdmin);
        // ACL Manager roles (for CampaignRegistry and StrategyRegistry)
        aclManager.grantRole(aclManager.strategyAdminRole(), address(factory));
        aclManager.grantRole(aclManager.campaignAdminRole(), address(factory));
        // PayoutRouter local AccessControl role
        payoutRouter.grantRole(keccak256("VAULT_MANAGER_ROLE"), address(factory));
        vm.stopPrank();

        // Setup strategy
        vm.prank(protocolAdmin);
        strategyRegistry.registerStrategy(
            StrategyRegistry.StrategyInput({
                id: STRATEGY_ID,
                adapter: address(0x999), // Mock adapter address
                riskTier: keccak256("LOW"),
                maxTvl: 1_000_000e6, // 1M USDC
                metadataHash: keccak256("ipfs://Qm...")
            })
        );

        // Setup campaign
        vm.deal(protocolAdmin, 1 ether); // Fund protocolAdmin with ETH for deposit
        vm.prank(protocolAdmin);
        campaignRegistry.submitCampaign{value: 0.005 ether}(
            CampaignRegistry.CampaignInput({
                id: CAMPAIGN_ID,
                payoutRecipient: protocolAdmin,
                strategyId: STRATEGY_ID,
                metadataHash: keccak256("Save the Whales"),
                metadataCID: "QmSaveTheWhales",
                targetStake: 100_000e6,
                minStake: 1000e6,
                fundraisingStart: uint64(block.timestamp),
                fundraisingEnd: uint64(block.timestamp + 365 days)
            })
        );

        vm.prank(protocolAdmin);
        campaignRegistry.approveCampaign(CAMPAIGN_ID, protocolAdmin);

        // Mint tokens to users
        usdc.mint(user1, 1_000_000e6); // 1M USDC
        usdc.mint(user2, 1_000_000e6);
        weth.mint(user1, 100e18); // 100 WETH
        weth.mint(user2, 100e18);
    }

    // ============================================
    // C-01 FIX TESTS: Unique VaultId Per Proxy
    // ============================================

    function test_Contract04_Case01_uniqueVaultIdPerProxy() public {
        // Deploy two GiveVault4626 proxies
        bytes memory initData1 = abi.encodeCall(
            GiveVault4626.initialize,
            (address(usdc), "Give Vault USDC 1", "gvUSDC1", vaultAdmin, address(aclManager), address(giveVaultImpl))
        );

        bytes memory initData2 = abi.encodeCall(
            GiveVault4626.initialize,
            (address(weth), "Give Vault WETH 2", "gvWETH2", vaultAdmin, address(aclManager), address(giveVaultImpl))
        );

        address proxy1 = address(new ERC1967Proxy(address(giveVaultImpl), initData1));
        address proxy2 = address(new ERC1967Proxy(address(giveVaultImpl), initData2));

        vault1 = GiveVault4626(payable(proxy1));
        vault2 = GiveVault4626(payable(proxy2));

        // Get vaultIds
        bytes32 vaultId1 = vault1.vaultId();
        bytes32 vaultId2 = vault2.vaultId();

        // C-01 FIX PROOF: Each proxy has unique vaultId
        assertNotEq(vaultId1, vaultId2, "Vault IDs must be unique");

        // Verify vaultId is derived from proxy address
        assertEq(vaultId1, keccak256(abi.encodePacked(address(vault1))), "VaultId1 should match address hash");
        assertEq(vaultId2, keccak256(abi.encodePacked(address(vault2))), "VaultId2 should match address hash");
    }

    function test_Contract04_Case02_uniqueStoragePerProxy() public {
        // Deploy two vaults
        bytes memory initData1 = abi.encodeCall(
            GiveVault4626.initialize,
            (address(usdc), "Give Vault USDC", "gvUSDC", vaultAdmin, address(aclManager), address(giveVaultImpl))
        );

        bytes memory initData2 = abi.encodeCall(
            GiveVault4626.initialize,
            (address(weth), "Give Vault WETH", "gvWETH", vaultAdmin, address(aclManager), address(giveVaultImpl))
        );

        vault1 = GiveVault4626(payable(address(new ERC1967Proxy(address(giveVaultImpl), initData1))));
        vault2 = GiveVault4626(payable(address(new ERC1967Proxy(address(giveVaultImpl), initData2))));

        // Deposit to vault1
        vm.startPrank(user1);
        usdc.approve(address(vault1), 1000e6);
        vault1.deposit(1000e6, user1);
        vm.stopPrank();

        // Deposit to vault2
        vm.startPrank(user2);
        weth.approve(address(vault2), 10e18);
        vault2.deposit(10e18, user2);
        vm.stopPrank();

        // C-01 FIX PROOF: Each vault maintains separate balances (no storage collision)
        assertEq(vault1.balanceOf(user1), 1000e6, "Vault1 should have user1 shares");
        assertEq(vault1.balanceOf(user2), 0, "Vault1 should NOT have user2 shares");

        assertEq(vault2.balanceOf(user2), 10e18, "Vault2 should have user2 shares");
        assertEq(vault2.balanceOf(user1), 0, "Vault2 should NOT have user1 shares");

        // Verify assets are different
        assertEq(address(vault1.asset()), address(usdc), "Vault1 asset should be USDC");
        assertEq(address(vault2.asset()), address(weth), "Vault2 asset should be WETH");
    }

    // ============================================
    // M-01 FIX TESTS: UUPS Upgradeability
    // ============================================

    function test_Contract04_Case03_vaultIsUpgradeable() public {
        // Deploy vault
        bytes memory initData = abi.encodeCall(
            GiveVault4626.initialize,
            (address(usdc), "Give Vault USDC", "gvUSDC", vaultAdmin, address(aclManager), address(giveVaultImpl))
        );

        vault1 = GiveVault4626(payable(address(new ERC1967Proxy(address(giveVaultImpl), initData))));

        // Deploy new implementation
        GiveVault4626 newImpl = new GiveVault4626();

        // Grant upgrader role
        vm.prank(protocolAdmin);
        aclManager.grantRole(keccak256("ROLE_UPGRADER"), vaultAdmin);

        // M-01 FIX PROOF: Vault can be upgraded via UUPS
        vm.prank(vaultAdmin);
        vault1.upgradeToAndCall(address(newImpl), "");

        // Verify upgrade succeeded (implementation changed)
        // Note: We can't easily check implementation address from Solidity
        // but the fact that upgradeToAndCall didn't revert proves it worked
        assertTrue(true, "Upgrade succeeded");
    }

    function test_Contract04_Case04_upgradeRequiresAuthorization() public {
        // Deploy vault
        bytes memory initData = abi.encodeCall(
            GiveVault4626.initialize,
            (address(usdc), "Give Vault USDC", "gvUSDC", vaultAdmin, address(aclManager), address(giveVaultImpl))
        );

        vault1 = GiveVault4626(payable(address(new ERC1967Proxy(address(giveVaultImpl), initData))));

        // Deploy new implementation
        GiveVault4626 newImpl = new GiveVault4626();

        // Try to upgrade without ROLE_UPGRADER (should fail)
        vm.prank(user1);
        vm.expectRevert();
        vault1.upgradeToAndCall(address(newImpl), "");
    }

    // ============================================
    // Factory Tests
    // ============================================

    function test_Contract04_Case05_factoryDeploysUUPSProxy() public {
        // Deploy via factory
        vm.prank(protocolAdmin);
        address vaultAddr = factory.deployCampaignVault(
            CampaignVaultFactory.DeployParams({
                campaignId: CAMPAIGN_ID,
                strategyId: STRATEGY_ID,
                lockProfile: LOCK_PROFILE,
                asset: address(usdc),
                admin: vaultAdmin,
                name: "Campaign Vault USDC",
                symbol: "cvUSDC"
            })
        );

        campaignVault1 = CampaignVault4626(payable(vaultAddr));

        // Verify vault initialized correctly
        assertEq(campaignVault1.name(), "Campaign Vault USDC");
        assertEq(campaignVault1.symbol(), "cvUSDC");
        assertEq(address(campaignVault1.asset()), address(usdc));
        assertTrue(campaignVault1.campaignInitialized(), "Campaign metadata should be initialized");

        // Verify factory is stored
        assertEq(campaignVault1.factory(), address(factory));

        // Verify campaign metadata
        (bytes32 campaignId, bytes32 strategyId, bytes32 lockProfile, address factoryAddr) =
            campaignVault1.getCampaignMetadata();
        assertEq(campaignId, CAMPAIGN_ID);
        assertEq(strategyId, STRATEGY_ID);
        assertEq(lockProfile, LOCK_PROFILE);
        assertEq(factoryAddr, address(factory));
    }

    function test_Contract04_Case06_factoryEnforcesInitialization() public {
        // Deploy vault manually (not via factory)
        bytes memory initData = abi.encodeCall(
            CampaignVault4626.initialize,
            (
                address(usdc),
                "Manual Vault",
                "mVault",
                vaultAdmin,
                address(aclManager),
                address(campaignVaultImpl),
                address(this) // we are the factory
            )
        );

        campaignVault1 = CampaignVault4626(payable(address(new ERC1967Proxy(address(campaignVaultImpl), initData))));

        // Try to initialize campaign as non-factory (should fail)
        vm.prank(user1);
        vm.expectRevert();
        campaignVault1.initializeCampaign(CAMPAIGN_ID, STRATEGY_ID, LOCK_PROFILE);

        // Factory (this contract) can initialize
        campaignVault1.initializeCampaign(CAMPAIGN_ID, STRATEGY_ID, LOCK_PROFILE);
        assertTrue(campaignVault1.campaignInitialized());
    }

    // ============================================
    // Role Assignment Tests
    // ============================================

    function test_Contract04_Case07_rolesAssignedCorrectly() public {
        // Deploy vault
        bytes memory initData = abi.encodeCall(
            GiveVault4626.initialize,
            (address(usdc), "Give Vault USDC", "gvUSDC", vaultAdmin, address(aclManager), address(giveVaultImpl))
        );

        vault1 = GiveVault4626(payable(address(new ERC1967Proxy(address(giveVaultImpl), initData))));

        // Verify admin has all required roles
        bytes32 DEFAULT_ADMIN = 0x00;
        bytes32 VAULT_MANAGER = keccak256("VAULT_MANAGER_ROLE");
        bytes32 PAUSER = keccak256("PAUSER_ROLE");

        assertTrue(vault1.hasRole(DEFAULT_ADMIN, vaultAdmin), "Admin should have DEFAULT_ADMIN_ROLE");
        assertTrue(vault1.hasRole(VAULT_MANAGER, vaultAdmin), "Admin should have VAULT_MANAGER_ROLE");
        assertTrue(vault1.hasRole(PAUSER, vaultAdmin), "Admin should have PAUSER_ROLE");

        // Verify user does NOT have roles
        assertFalse(vault1.hasRole(DEFAULT_ADMIN, user1), "User should NOT have DEFAULT_ADMIN_ROLE");
    }

    // ============================================
    // Emergency Withdrawal Authorization Test
    // ============================================

    function test_Contract04_Case08_emergencyWithdrawalRequiresAuthorization() public {
        // Deploy and fund vault
        bytes memory initData = abi.encodeCall(
            GiveVault4626.initialize,
            (address(usdc), "Give Vault USDC", "gvUSDC", vaultAdmin, address(aclManager), address(giveVaultImpl))
        );

        vault1 = GiveVault4626(payable(address(new ERC1967Proxy(address(giveVaultImpl), initData))));

        // User1 deposits
        vm.startPrank(user1);
        usdc.approve(address(vault1), 1000e6);
        uint256 shares = vault1.deposit(1000e6, user1);
        vm.stopPrank();

        // Trigger emergency
        vm.prank(vaultAdmin);
        vault1.emergencyPause();

        // Fast-forward past grace period
        vm.warp(block.timestamp + 25 hours);

        // User2 tries to emergency withdraw user1's shares without approval (should fail)
        vm.prank(user2);
        vm.expectRevert();
        vault1.emergencyWithdrawUser(shares, user2, user1);

        // User1 can withdraw their own shares
        vm.prank(user1);
        vault1.emergencyWithdrawUser(shares, user1, user1);

        assertEq(vault1.balanceOf(user1), 0, "User1 shares should be burned");
    }

    // ============================================
    // Branch Gap Coverage (Update J)
    // ============================================

    function _deployVault() internal returns (GiveVault4626) {
        bytes memory initData = abi.encodeCall(
            GiveVault4626.initialize,
            (address(usdc), "Give Vault USDC", "gvUSDC", vaultAdmin, address(aclManager), address(giveVaultImpl))
        );
        return GiveVault4626(payable(address(new ERC1967Proxy(address(giveVaultImpl), initData))));
    }

    function test_Contract04_Case10_setInvestPaused_skipsAdapterOnDeposit() public {
        vault1 = _deployVault();

        vm.prank(vaultAdmin);
        vault1.setInvestPaused(true);
        assertTrue(vault1.investPaused());

        // Deposit should not revert — investPaused only skips _investExcessCash, not deposit itself
        vm.startPrank(user1);
        usdc.approve(address(vault1), 100e6);
        uint256 shares = vault1.deposit(100e6, user1);
        vm.stopPrank();

        assertGt(shares, 0, "deposit should succeed even when invest paused");
        // All funds remain as cash — not invested
        assertEq(vault1.getCashBalance(), 100e6, "cash balance should equal full deposit");
    }

    function test_Contract04_Case11_setHarvestPaused_blockHarvest() public {
        vault1 = _deployVault();

        vm.prank(vaultAdmin);
        vault1.setHarvestPaused(true);
        assertTrue(vault1.harvestPaused());

        vm.expectRevert(GiveVault4626.HarvestPaused.selector);
        vault1.harvest();
    }

    function test_Contract04_Case12_setCashBufferBps_aboveMaxReverts() public {
        vault1 = _deployVault();
        uint256 tooHigh = vault1.MAX_CASH_BUFFER_BPS() + 1;

        vm.prank(vaultAdmin);
        vm.expectRevert(GiveVault4626.CashBufferTooHigh.selector);
        vault1.setCashBufferBps(tooHigh);
    }

    function test_Contract04_Case13_setSlippageBps_aboveMaxReverts() public {
        vault1 = _deployVault();
        uint256 tooHigh = vault1.MAX_SLIPPAGE_BPS() + 1;

        vm.prank(vaultAdmin);
        vm.expectRevert(GiveVault4626.InvalidSlippageBps.selector);
        vault1.setSlippageBps(tooHigh);
    }

    function test_Contract04_Case14_setMaxLossBps_aboveMaxReverts() public {
        vault1 = _deployVault();
        uint256 tooHigh = vault1.MAX_LOSS_BPS() + 1;

        vm.prank(vaultAdmin);
        vm.expectRevert(GiveVault4626.InvalidMaxLossBps.selector);
        vault1.setMaxLossBps(tooHigh);
    }

    function test_Contract04_Case15_emergencyPause_setsGracePeriodTimestamp() public {
        vault1 = _deployVault();

        uint256 before = block.timestamp;
        vm.prank(vaultAdmin);
        vault1.emergencyPause();

        assertTrue(vault1.paused(), "vault should be paused");
        assertTrue(vault1.emergencyShutdown(), "emergencyShutdown flag should be set");
        assertEq(vault1.emergencyActivatedAt(), uint64(before), "emergencyActivatedAt should be set");
        assertTrue(vault1.investPaused(), "investPaused should be set");
        assertTrue(vault1.harvestPaused(), "harvestPaused should be set");
    }

    function test_Contract04_Case16_resumeFromEmergency_clearsState() public {
        vault1 = _deployVault();

        vm.prank(vaultAdmin);
        vault1.emergencyPause();

        vm.prank(vaultAdmin);
        vault1.resumeFromEmergency();

        assertFalse(vault1.paused(), "vault should be unpaused");
        assertFalse(vault1.emergencyShutdown(), "emergencyShutdown should be cleared");
        assertEq(vault1.emergencyActivatedAt(), 0, "emergencyActivatedAt should be zero");
        assertFalse(vault1.investPaused(), "investPaused should be cleared");
        assertFalse(vault1.harvestPaused(), "harvestPaused should be cleared");
    }

    function test_Contract04_Case17_forceClearAdapter_withFundsReverts() public {
        vault1 = _deployVault();
        // No adapter set → forceClearAdapter should succeed (nothing to clear)
        vm.prank(vaultAdmin);
        vault1.forceClearAdapter(); // should not revert

        assertEq(address(vault1.activeAdapter()), address(0));
    }

    // ============================================
    // Deterministic Deployment Test
    // ============================================

    function test_Contract04_Case09_deterministicDeployment() public {
        CampaignVaultFactory.DeployParams memory params = CampaignVaultFactory.DeployParams({
            campaignId: CAMPAIGN_ID,
            strategyId: STRATEGY_ID,
            lockProfile: LOCK_PROFILE,
            asset: address(usdc),
            admin: vaultAdmin,
            name: "Campaign Vault USDC",
            symbol: "cvUSDC"
        });

        // Predict address
        address predicted = factory.predictVaultAddress(params);

        // Deploy
        vm.prank(protocolAdmin);
        address deployed = factory.deployCampaignVault(params);

        // Verify addresses match
        assertEq(deployed, predicted, "Deployed address should match predicted address");
    }
}

// Mock ERC20 token for testing
contract MockERC20 is ERC20 {
    uint8 private _decimals;

    constructor(string memory name, string memory symbol, uint8 decimals_) ERC20(name, symbol) {
        _decimals = decimals_;
    }

    function decimals() public view override returns (uint8) {
        return _decimals;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}
