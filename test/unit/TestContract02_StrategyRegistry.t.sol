// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test, console} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {StrategyRegistry} from "../../src/registry/StrategyRegistry.sol";
import {ACLManager} from "../../src/governance/ACLManager.sol";
import {GiveTypes} from "../../src/types/GiveTypes.sol";

/**
 * @title   TestContract02_StrategyRegistry
 * @author  GIVE Labs
 * @notice  Comprehensive test suite for StrategyRegistry contract
 * @dev     Tests strategy registration, lifecycle management, vault linking, and UUPS upgradeability.
 *          Covers all strategy status transitions and access control scenarios.
 */
contract TestContract02_StrategyRegistry is Test {
    StrategyRegistry public strategyRegistry;
    StrategyRegistry public implementation;
    ACLManager public aclManager;
    ERC1967Proxy public proxy;

    address public superAdmin;
    address public strategyAdmin;
    address public upgrader;
    address public user1;
    address public user2;

    bytes32 public constant ROLE_SUPER_ADMIN = keccak256("ROLE_SUPER_ADMIN");
    bytes32 public constant ROLE_UPGRADER = keccak256("ROLE_UPGRADER");
    bytes32 public constant ROLE_STRATEGY_ADMIN = keccak256("ROLE_STRATEGY_ADMIN");

    bytes32 public constant STRATEGY_ID_1 = keccak256("STRATEGY_AAVE_USDC");
    bytes32 public constant STRATEGY_ID_2 = keccak256("STRATEGY_COMPOUND_DAI");
    bytes32 public constant RISK_LOW = keccak256("LOW");
    bytes32 public constant RISK_MEDIUM = keccak256("MEDIUM");
    bytes32 public constant METADATA_HASH = keccak256("ipfs://Qm...");

    address public adapter1;
    address public adapter2;
    address public vault1;
    address public vault2;

    event StrategyRegistered(
        bytes32 indexed id, address indexed adapter, bytes32 riskTier, uint256 maxTvl, bytes32 metadataHash
    );
    event StrategyUpdated(
        bytes32 indexed id, address indexed adapter, bytes32 riskTier, uint256 maxTvl, bytes32 metadataHash
    );
    event StrategyStatusChanged(
        bytes32 indexed id, GiveTypes.StrategyStatus previousStatus, GiveTypes.StrategyStatus newStatus
    );
    event StrategyVaultLinked(bytes32 indexed strategyId, address indexed vault);
    event StrategyVaultUnlinked(bytes32 indexed strategyId, address indexed vault);

    function setUp() public {
        superAdmin = address(this);
        strategyAdmin = address(0x1);
        upgrader = address(0x2);
        user1 = address(0x3);
        user2 = address(0x4);

        adapter1 = address(0x100);
        adapter2 = address(0x200);
        vault1 = address(0x1000);
        vault2 = address(0x2000);

        // Deploy ACLManager
        ACLManager aclImpl = new ACLManager();
        bytes memory aclInitData = abi.encodeWithSelector(ACLManager.initialize.selector, superAdmin, upgrader);
        ERC1967Proxy aclProxy = new ERC1967Proxy(address(aclImpl), aclInitData);
        aclManager = ACLManager(address(aclProxy));

        // Grant STRATEGY_ADMIN role
        aclManager.grantRole(ROLE_STRATEGY_ADMIN, strategyAdmin);

        // Deploy StrategyRegistry
        implementation = new StrategyRegistry();
        bytes memory initData = abi.encodeWithSelector(StrategyRegistry.initialize.selector, address(aclManager));
        proxy = new ERC1967Proxy(address(implementation), initData);
        strategyRegistry = StrategyRegistry(address(proxy));

        console.log("StrategyRegistry proxy deployed at:", address(strategyRegistry));
        console.log("ACLManager deployed at:", address(aclManager));
        console.log("Strategy admin:", strategyAdmin);
    }

    // ============================================
    // INITIALIZATION TESTS
    // ============================================

    /**
     * @dev Test initial deployment state
     */
    function test_Contract02_Case01_initializationState() public {
        assertEq(address(strategyRegistry.aclManager()), address(aclManager), "ACL manager should be set");

        bytes32[] memory ids = strategyRegistry.listStrategyIds();
        assertEq(ids.length, 0, "Should have no strategies initially");
    }

    /**
     * @dev Test that initialize cannot be called twice
     */
    function test_Contract02_Case02_cannotReinitialize() public {
        vm.expectRevert();
        strategyRegistry.initialize(address(aclManager));
    }

    /**
     * @dev Test initialize with zero address reverts
     */
    function test_Contract02_Case03_initializeZeroAddressReverts() public {
        StrategyRegistry newImpl = new StrategyRegistry();
        bytes memory initData = abi.encodeWithSelector(StrategyRegistry.initialize.selector, address(0));

        vm.expectRevert(StrategyRegistry.ZeroAddress.selector);
        new ERC1967Proxy(address(newImpl), initData);
    }

    // ============================================
    // STRATEGY REGISTRATION TESTS
    // ============================================

    /**
     * @dev Test registering a new strategy
     */
    function test_Contract02_Case04_registerStrategy() public {
        StrategyRegistry.StrategyInput memory input = StrategyRegistry.StrategyInput({
            id: STRATEGY_ID_1,
            adapter: adapter1,
            riskTier: RISK_LOW,
            maxTvl: 1_000_000e6, // 1M USDC
            metadataHash: METADATA_HASH
        });

        vm.prank(strategyAdmin);
        vm.expectEmit(true, true, false, true);
        emit StrategyRegistered(STRATEGY_ID_1, adapter1, RISK_LOW, 1_000_000e6, METADATA_HASH);
        strategyRegistry.registerStrategy(input);

        GiveTypes.StrategyConfig memory cfg = strategyRegistry.getStrategy(STRATEGY_ID_1);
        assertEq(cfg.id, STRATEGY_ID_1, "ID should match");
        assertEq(cfg.adapter, adapter1, "Adapter should match");
        assertEq(cfg.riskTier, RISK_LOW, "Risk tier should match");
        assertEq(cfg.maxTvl, 1_000_000e6, "Max TVL should match");
        assertEq(cfg.metadataHash, METADATA_HASH, "Metadata hash should match");
        assertEq(cfg.creator, strategyAdmin, "Creator should be strategy admin");
        assertTrue(cfg.exists, "Strategy should exist");
        assertEq(uint256(cfg.status), uint256(GiveTypes.StrategyStatus.Active), "Status should be Active");
    }

    /**
     * @dev Test only strategy admin can register
     */
    function test_Contract02_Case05_onlyStrategyAdminCanRegister() public {
        StrategyRegistry.StrategyInput memory input = StrategyRegistry.StrategyInput({
            id: STRATEGY_ID_1, adapter: adapter1, riskTier: RISK_LOW, maxTvl: 1_000_000e6, metadataHash: METADATA_HASH
        });

        vm.prank(user1);
        vm.expectRevert(abi.encodeWithSelector(StrategyRegistry.Unauthorized.selector, ROLE_STRATEGY_ADMIN, user1));
        strategyRegistry.registerStrategy(input);
    }

    /**
     * @dev Test cannot register duplicate strategy
     */
    function test_Contract02_Case06_cannotRegisterDuplicate() public {
        StrategyRegistry.StrategyInput memory input = StrategyRegistry.StrategyInput({
            id: STRATEGY_ID_1, adapter: adapter1, riskTier: RISK_LOW, maxTvl: 1_000_000e6, metadataHash: METADATA_HASH
        });

        vm.startPrank(strategyAdmin);
        strategyRegistry.registerStrategy(input);

        vm.expectRevert(abi.encodeWithSelector(StrategyRegistry.StrategyAlreadyExists.selector, STRATEGY_ID_1));
        strategyRegistry.registerStrategy(input);
        vm.stopPrank();
    }

    /**
     * @dev Test registration with invalid parameters reverts
     */
    function test_Contract02_Case07_registerInvalidParametersReverts() public {
        vm.startPrank(strategyAdmin);

        // Zero ID
        StrategyRegistry.StrategyInput memory input1 = StrategyRegistry.StrategyInput({
            id: bytes32(0), adapter: adapter1, riskTier: RISK_LOW, maxTvl: 1_000_000e6, metadataHash: METADATA_HASH
        });
        vm.expectRevert(abi.encodeWithSelector(StrategyRegistry.InvalidStrategyConfig.selector, bytes32(0)));
        strategyRegistry.registerStrategy(input1);

        // Zero adapter
        StrategyRegistry.StrategyInput memory input2 = StrategyRegistry.StrategyInput({
            id: STRATEGY_ID_1, adapter: address(0), riskTier: RISK_LOW, maxTvl: 1_000_000e6, metadataHash: METADATA_HASH
        });
        vm.expectRevert(abi.encodeWithSelector(StrategyRegistry.InvalidStrategyConfig.selector, STRATEGY_ID_1));
        strategyRegistry.registerStrategy(input2);

        // Zero maxTvl
        StrategyRegistry.StrategyInput memory input3 = StrategyRegistry.StrategyInput({
            id: STRATEGY_ID_1, adapter: adapter1, riskTier: RISK_LOW, maxTvl: 0, metadataHash: METADATA_HASH
        });
        vm.expectRevert(abi.encodeWithSelector(StrategyRegistry.InvalidStrategyConfig.selector, STRATEGY_ID_1));
        strategyRegistry.registerStrategy(input3);

        vm.stopPrank();
    }

    // ============================================
    // STRATEGY UPDATE TESTS
    // ============================================

    /**
     * @dev Test updating an existing strategy
     */
    function test_Contract02_Case08_updateStrategy() public {
        // Register first
        vm.prank(strategyAdmin);
        strategyRegistry.registerStrategy(
            StrategyRegistry.StrategyInput({
                id: STRATEGY_ID_1,
                adapter: adapter1,
                riskTier: RISK_LOW,
                maxTvl: 1_000_000e6,
                metadataHash: METADATA_HASH
            })
        );

        // Update
        bytes32 newMetadata = keccak256("ipfs://Qm...new");
        vm.prank(strategyAdmin);
        vm.expectEmit(true, true, false, true);
        emit StrategyUpdated(STRATEGY_ID_1, adapter2, RISK_MEDIUM, 2_000_000e6, newMetadata);
        strategyRegistry.updateStrategy(
            StrategyRegistry.StrategyInput({
                id: STRATEGY_ID_1,
                adapter: adapter2,
                riskTier: RISK_MEDIUM,
                maxTvl: 2_000_000e6,
                metadataHash: newMetadata
            })
        );

        GiveTypes.StrategyConfig memory cfg = strategyRegistry.getStrategy(STRATEGY_ID_1);
        assertEq(cfg.adapter, adapter2, "Adapter should be updated");
        assertEq(cfg.riskTier, RISK_MEDIUM, "Risk tier should be updated");
        assertEq(cfg.maxTvl, 2_000_000e6, "Max TVL should be updated");
        assertEq(cfg.metadataHash, newMetadata, "Metadata should be updated");
    }

    /**
     * @dev Test updating non-existent strategy reverts
     */
    function test_Contract02_Case09_updateNonExistentStrategyReverts() public {
        vm.prank(strategyAdmin);
        vm.expectRevert(abi.encodeWithSelector(StrategyRegistry.StrategyNotFound.selector, STRATEGY_ID_1));
        strategyRegistry.updateStrategy(
            StrategyRegistry.StrategyInput({
                id: STRATEGY_ID_1,
                adapter: adapter1,
                riskTier: RISK_LOW,
                maxTvl: 1_000_000e6,
                metadataHash: METADATA_HASH
            })
        );
    }

    // ============================================
    // STRATEGY STATUS TESTS
    // ============================================

    /**
     * @dev Test changing strategy status
     */
    function test_Contract02_Case10_changeStrategyStatus() public {
        // Register
        vm.prank(strategyAdmin);
        strategyRegistry.registerStrategy(
            StrategyRegistry.StrategyInput({
                id: STRATEGY_ID_1,
                adapter: adapter1,
                riskTier: RISK_LOW,
                maxTvl: 1_000_000e6,
                metadataHash: METADATA_HASH
            })
        );

        // Change to FadingOut
        vm.prank(strategyAdmin);
        vm.expectEmit(true, false, false, true);
        emit StrategyStatusChanged(STRATEGY_ID_1, GiveTypes.StrategyStatus.Active, GiveTypes.StrategyStatus.FadingOut);
        strategyRegistry.setStrategyStatus(STRATEGY_ID_1, GiveTypes.StrategyStatus.FadingOut);

        GiveTypes.StrategyConfig memory cfg = strategyRegistry.getStrategy(STRATEGY_ID_1);
        assertEq(uint256(cfg.status), uint256(GiveTypes.StrategyStatus.FadingOut), "Status should be FadingOut");

        // Change to Deprecated
        vm.prank(strategyAdmin);
        emit StrategyStatusChanged(
            STRATEGY_ID_1, GiveTypes.StrategyStatus.FadingOut, GiveTypes.StrategyStatus.Deprecated
        );
        strategyRegistry.setStrategyStatus(STRATEGY_ID_1, GiveTypes.StrategyStatus.Deprecated);

        cfg = strategyRegistry.getStrategy(STRATEGY_ID_1);
        assertEq(uint256(cfg.status), uint256(GiveTypes.StrategyStatus.Deprecated), "Status should be Deprecated");
    }

    /**
     * @dev Test setting status to Unknown reverts
     */
    function test_Contract02_Case11_setStatusToUnknownReverts() public {
        vm.prank(strategyAdmin);
        strategyRegistry.registerStrategy(
            StrategyRegistry.StrategyInput({
                id: STRATEGY_ID_1,
                adapter: adapter1,
                riskTier: RISK_LOW,
                maxTvl: 1_000_000e6,
                metadataHash: METADATA_HASH
            })
        );

        vm.prank(strategyAdmin);
        vm.expectRevert(abi.encodeWithSelector(StrategyRegistry.InvalidStrategyConfig.selector, STRATEGY_ID_1));
        strategyRegistry.setStrategyStatus(STRATEGY_ID_1, GiveTypes.StrategyStatus.Unknown);
    }

    /**
     * @dev Test status change is idempotent
     */
    function test_Contract02_Case12_statusChangeIdempotent() public {
        vm.prank(strategyAdmin);
        strategyRegistry.registerStrategy(
            StrategyRegistry.StrategyInput({
                id: STRATEGY_ID_1,
                adapter: adapter1,
                riskTier: RISK_LOW,
                maxTvl: 1_000_000e6,
                metadataHash: METADATA_HASH
            })
        );

        // Change to FadingOut twice - should not revert or emit event second time
        vm.prank(strategyAdmin);
        strategyRegistry.setStrategyStatus(STRATEGY_ID_1, GiveTypes.StrategyStatus.FadingOut);

        vm.prank(strategyAdmin);
        strategyRegistry.setStrategyStatus(STRATEGY_ID_1, GiveTypes.StrategyStatus.FadingOut);

        GiveTypes.StrategyConfig memory cfg = strategyRegistry.getStrategy(STRATEGY_ID_1);
        assertEq(uint256(cfg.status), uint256(GiveTypes.StrategyStatus.FadingOut), "Status should remain FadingOut");
    }

    // ============================================
    // VAULT LINKING TESTS
    // ============================================

    /**
     * @dev Test linking vaults to strategy
     */
    function test_Contract02_Case13_linkVaultToStrategy() public {
        vm.prank(strategyAdmin);
        strategyRegistry.registerStrategy(
            StrategyRegistry.StrategyInput({
                id: STRATEGY_ID_1,
                adapter: adapter1,
                riskTier: RISK_LOW,
                maxTvl: 1_000_000e6,
                metadataHash: METADATA_HASH
            })
        );

        vm.prank(strategyAdmin);
        vm.expectEmit(true, true, false, true);
        emit StrategyVaultLinked(STRATEGY_ID_1, vault1);
        strategyRegistry.registerStrategyVault(STRATEGY_ID_1, vault1);

        address[] memory vaults = strategyRegistry.getStrategyVaults(STRATEGY_ID_1);
        assertEq(vaults.length, 1, "Should have 1 vault");
        assertEq(vaults[0], vault1, "Vault should be vault1");
    }

    /**
     * @dev Test linking multiple vaults (reusability)
     */
    function test_Contract02_Case14_linkMultipleVaults() public {
        vm.prank(strategyAdmin);
        strategyRegistry.registerStrategy(
            StrategyRegistry.StrategyInput({
                id: STRATEGY_ID_1,
                adapter: adapter1,
                riskTier: RISK_LOW,
                maxTvl: 1_000_000e6,
                metadataHash: METADATA_HASH
            })
        );

        vm.startPrank(strategyAdmin);
        strategyRegistry.registerStrategyVault(STRATEGY_ID_1, vault1);
        strategyRegistry.registerStrategyVault(STRATEGY_ID_1, vault2);
        vm.stopPrank();

        address[] memory vaults = strategyRegistry.getStrategyVaults(STRATEGY_ID_1);
        assertEq(vaults.length, 2, "Should have 2 vaults");
        assertEq(vaults[0], vault1, "First vault should be vault1");
        assertEq(vaults[1], vault2, "Second vault should be vault2");
    }

    /**
     * @dev Test linking vault to non-existent strategy reverts
     */
    function test_Contract02_Case15_linkVaultToNonExistentStrategyReverts() public {
        vm.prank(strategyAdmin);
        vm.expectRevert(abi.encodeWithSelector(StrategyRegistry.StrategyNotFound.selector, STRATEGY_ID_1));
        strategyRegistry.registerStrategyVault(STRATEGY_ID_1, vault1);
    }

    /**
     * @dev Test linking zero address vault reverts
     */
    function test_Contract02_Case16_linkZeroAddressVaultReverts() public {
        vm.prank(strategyAdmin);
        strategyRegistry.registerStrategy(
            StrategyRegistry.StrategyInput({
                id: STRATEGY_ID_1,
                adapter: adapter1,
                riskTier: RISK_LOW,
                maxTvl: 1_000_000e6,
                metadataHash: METADATA_HASH
            })
        );

        vm.prank(strategyAdmin);
        vm.expectRevert(StrategyRegistry.ZeroAddress.selector);
        strategyRegistry.registerStrategyVault(STRATEGY_ID_1, address(0));
    }

    // ============================================
    // VIEW FUNCTION TESTS
    // ============================================

    /**
     * @dev Test getStrategy for non-existent strategy reverts
     */
    function test_Contract02_Case17_getNonExistentStrategyReverts() public {
        vm.expectRevert(abi.encodeWithSelector(StrategyRegistry.StrategyNotFound.selector, STRATEGY_ID_1));
        strategyRegistry.getStrategy(STRATEGY_ID_1);
    }

    /**
     * @dev Test listStrategyIds
     */
    function test_Contract02_Case18_listStrategyIds() public {
        vm.startPrank(strategyAdmin);

        strategyRegistry.registerStrategy(
            StrategyRegistry.StrategyInput({
                id: STRATEGY_ID_1,
                adapter: adapter1,
                riskTier: RISK_LOW,
                maxTvl: 1_000_000e6,
                metadataHash: METADATA_HASH
            })
        );

        strategyRegistry.registerStrategy(
            StrategyRegistry.StrategyInput({
                id: STRATEGY_ID_2,
                adapter: adapter2,
                riskTier: RISK_MEDIUM,
                maxTvl: 2_000_000e6,
                metadataHash: METADATA_HASH
            })
        );

        vm.stopPrank();

        bytes32[] memory ids = strategyRegistry.listStrategyIds();
        assertEq(ids.length, 2, "Should have 2 strategies");
        assertEq(ids[0], STRATEGY_ID_1, "First ID should match");
        assertEq(ids[1], STRATEGY_ID_2, "Second ID should match");
    }

    /**
     * @dev Test getStrategyVaults for strategy with no vaults
     */
    function test_Contract02_Case19_getVaultsForStrategyWithNoVaults() public {
        vm.prank(strategyAdmin);
        strategyRegistry.registerStrategy(
            StrategyRegistry.StrategyInput({
                id: STRATEGY_ID_1,
                adapter: adapter1,
                riskTier: RISK_LOW,
                maxTvl: 1_000_000e6,
                metadataHash: METADATA_HASH
            })
        );

        address[] memory vaults = strategyRegistry.getStrategyVaults(STRATEGY_ID_1);
        assertEq(vaults.length, 0, "Should have no vaults");
    }

    // ============================================
    // UUPS UPGRADE TESTS
    // ============================================

    /**
     * @dev Test only upgrader can upgrade
     */
    function test_Contract02_Case20_onlyUpgraderCanUpgrade() public {
        StrategyRegistry newImpl = new StrategyRegistry();

        // Upgrader can upgrade
        vm.prank(upgrader);
        strategyRegistry.upgradeToAndCall(address(newImpl), "");

        // Non-upgrader cannot upgrade
        StrategyRegistry newerImpl = new StrategyRegistry();
        vm.prank(user1);
        vm.expectRevert(abi.encodeWithSelector(StrategyRegistry.Unauthorized.selector, ROLE_UPGRADER, user1));
        strategyRegistry.upgradeToAndCall(address(newerImpl), "");
    }

    /**
     * @dev Test state persists after upgrade
     */
    function test_Contract02_Case21_statePersistsAfterUpgrade() public {
        // Register strategy
        vm.prank(strategyAdmin);
        strategyRegistry.registerStrategy(
            StrategyRegistry.StrategyInput({
                id: STRATEGY_ID_1,
                adapter: adapter1,
                riskTier: RISK_LOW,
                maxTvl: 1_000_000e6,
                metadataHash: METADATA_HASH
            })
        );

        // Upgrade
        StrategyRegistry newImpl = new StrategyRegistry();
        vm.prank(upgrader);
        strategyRegistry.upgradeToAndCall(address(newImpl), "");

        // Verify state persisted
        GiveTypes.StrategyConfig memory cfg = strategyRegistry.getStrategy(STRATEGY_ID_1);
        assertEq(cfg.id, STRATEGY_ID_1, "Strategy should persist after upgrade");
        assertEq(cfg.adapter, adapter1, "Adapter should persist");
    }

    // ============================================
    // ACCESS CONTROL TESTS
    // ============================================

    /**
     * @dev Test non-admin cannot update status
     */
    function test_Contract02_Case22_nonAdminCannotUpdateStatus() public {
        vm.prank(strategyAdmin);
        strategyRegistry.registerStrategy(
            StrategyRegistry.StrategyInput({
                id: STRATEGY_ID_1,
                adapter: adapter1,
                riskTier: RISK_LOW,
                maxTvl: 1_000_000e6,
                metadataHash: METADATA_HASH
            })
        );

        vm.prank(user1);
        vm.expectRevert(abi.encodeWithSelector(StrategyRegistry.Unauthorized.selector, ROLE_STRATEGY_ADMIN, user1));
        strategyRegistry.setStrategyStatus(STRATEGY_ID_1, GiveTypes.StrategyStatus.FadingOut);
    }

    /**
     * @dev Test non-admin cannot link vaults
     */
    function test_Contract02_Case23_nonAdminCannotLinkVault() public {
        vm.prank(strategyAdmin);
        strategyRegistry.registerStrategy(
            StrategyRegistry.StrategyInput({
                id: STRATEGY_ID_1,
                adapter: adapter1,
                riskTier: RISK_LOW,
                maxTvl: 1_000_000e6,
                metadataHash: METADATA_HASH
            })
        );

        vm.prank(user1);
        vm.expectRevert(abi.encodeWithSelector(StrategyRegistry.Unauthorized.selector, ROLE_STRATEGY_ADMIN, user1));
        strategyRegistry.registerStrategyVault(STRATEGY_ID_1, vault1);
    }

    /**
     * @dev Test non-admin cannot update strategy
     */
    function test_Contract02_Case25_nonAdminCannotUpdateStrategy() public {
        vm.prank(strategyAdmin);
        strategyRegistry.registerStrategy(
            StrategyRegistry.StrategyInput({
                id: STRATEGY_ID_1,
                adapter: adapter1,
                riskTier: RISK_LOW,
                maxTvl: 1_000_000e6,
                metadataHash: METADATA_HASH
            })
        );

        vm.prank(user1);
        vm.expectRevert(abi.encodeWithSelector(StrategyRegistry.Unauthorized.selector, ROLE_STRATEGY_ADMIN, user1));
        strategyRegistry.updateStrategy(
            StrategyRegistry.StrategyInput({
                id: STRATEGY_ID_1,
                adapter: adapter2,
                riskTier: RISK_MEDIUM,
                maxTvl: 2_000_000e6,
                metadataHash: METADATA_HASH
            })
        );
    }

    /**
     * @dev Test setting status on non-existent strategy reverts
     */
    function test_Contract02_Case26_setStatusOnNonExistentStrategyReverts() public {
        vm.prank(strategyAdmin);
        vm.expectRevert(abi.encodeWithSelector(StrategyRegistry.StrategyNotFound.selector, STRATEGY_ID_1));
        strategyRegistry.setStrategyStatus(STRATEGY_ID_1, GiveTypes.StrategyStatus.FadingOut);
    }

    // ============================================
    // VAULT DEDUPLICATION & UNREGISTRATION TESTS
    // ============================================

    /**
     * @dev Test duplicate vault registration is prevented
     */
    function test_Contract02_Case27_duplicateVaultRegistrationReverts() public {
        vm.startPrank(strategyAdmin);

        strategyRegistry.registerStrategy(
            StrategyRegistry.StrategyInput({
                id: STRATEGY_ID_1,
                adapter: adapter1,
                riskTier: RISK_LOW,
                maxTvl: 1_000_000e6,
                metadataHash: METADATA_HASH
            })
        );

        // First registration should succeed
        strategyRegistry.registerStrategyVault(STRATEGY_ID_1, vault1);

        // Duplicate registration should revert
        vm.expectRevert(abi.encodeWithSelector(StrategyRegistry.VaultAlreadyRegistered.selector, STRATEGY_ID_1, vault1));
        strategyRegistry.registerStrategyVault(STRATEGY_ID_1, vault1);

        vm.stopPrank();
    }

    /**
     * @dev Test successful vault unregistration
     */
    function test_Contract02_Case28_unregisterVaultSucceeds() public {
        vm.startPrank(strategyAdmin);

        strategyRegistry.registerStrategy(
            StrategyRegistry.StrategyInput({
                id: STRATEGY_ID_1,
                adapter: adapter1,
                riskTier: RISK_LOW,
                maxTvl: 1_000_000e6,
                metadataHash: METADATA_HASH
            })
        );

        // Register two vaults
        strategyRegistry.registerStrategyVault(STRATEGY_ID_1, vault1);
        strategyRegistry.registerStrategyVault(STRATEGY_ID_1, vault2);

        address[] memory vaultsBefore = strategyRegistry.getStrategyVaults(STRATEGY_ID_1);
        assertEq(vaultsBefore.length, 2, "Should have 2 vaults");

        // Unregister vault1
        vm.expectEmit(true, true, false, false);
        emit StrategyVaultUnlinked(STRATEGY_ID_1, vault1);
        strategyRegistry.unregisterStrategyVault(STRATEGY_ID_1, vault1);

        address[] memory vaultsAfter = strategyRegistry.getStrategyVaults(STRATEGY_ID_1);
        assertEq(vaultsAfter.length, 1, "Should have 1 vault");
        assertEq(vaultsAfter[0], vault2, "Remaining vault should be vault2");

        vm.stopPrank();
    }

    /**
     * @dev Test unregistering non-existent vault reverts
     */
    function test_Contract02_Case29_unregisterNonExistentVaultReverts() public {
        vm.startPrank(strategyAdmin);

        strategyRegistry.registerStrategy(
            StrategyRegistry.StrategyInput({
                id: STRATEGY_ID_1,
                adapter: adapter1,
                riskTier: RISK_LOW,
                maxTvl: 1_000_000e6,
                metadataHash: METADATA_HASH
            })
        );

        // Try to unregister vault that was never registered
        vm.expectRevert(abi.encodeWithSelector(StrategyRegistry.VaultNotRegistered.selector, STRATEGY_ID_1, vault1));
        strategyRegistry.unregisterStrategyVault(STRATEGY_ID_1, vault1);

        vm.stopPrank();
    }

    /**
     * @dev Test unauthorized unregistration reverts
     */
    function test_Contract02_Case30_nonAdminCannotUnregisterVault() public {
        vm.prank(strategyAdmin);
        strategyRegistry.registerStrategy(
            StrategyRegistry.StrategyInput({
                id: STRATEGY_ID_1,
                adapter: adapter1,
                riskTier: RISK_LOW,
                maxTvl: 1_000_000e6,
                metadataHash: METADATA_HASH
            })
        );

        vm.prank(strategyAdmin);
        strategyRegistry.registerStrategyVault(STRATEGY_ID_1, vault1);

        vm.prank(user1);
        vm.expectRevert(abi.encodeWithSelector(StrategyRegistry.Unauthorized.selector, ROLE_STRATEGY_ADMIN, user1));
        strategyRegistry.unregisterStrategyVault(STRATEGY_ID_1, vault1);
    }

    /**
     * @dev Test re-registration after unregistration succeeds
     */
    function test_Contract02_Case31_reRegistrationAfterUnregisterSucceeds() public {
        vm.startPrank(strategyAdmin);

        strategyRegistry.registerStrategy(
            StrategyRegistry.StrategyInput({
                id: STRATEGY_ID_1,
                adapter: adapter1,
                riskTier: RISK_LOW,
                maxTvl: 1_000_000e6,
                metadataHash: METADATA_HASH
            })
        );

        // Register vault
        strategyRegistry.registerStrategyVault(STRATEGY_ID_1, vault1);

        // Unregister vault
        strategyRegistry.unregisterStrategyVault(STRATEGY_ID_1, vault1);

        address[] memory vaultsAfterUnregister = strategyRegistry.getStrategyVaults(STRATEGY_ID_1);
        assertEq(vaultsAfterUnregister.length, 0, "Should have 0 vaults after unregistration");

        // Re-register should succeed
        vm.expectEmit(true, true, false, false);
        emit StrategyVaultLinked(STRATEGY_ID_1, vault1);
        strategyRegistry.registerStrategyVault(STRATEGY_ID_1, vault1);

        address[] memory vaultsAfterReRegister = strategyRegistry.getStrategyVaults(STRATEGY_ID_1);
        assertEq(vaultsAfterReRegister.length, 1, "Should have 1 vault after re-registration");
        assertEq(vaultsAfterReRegister[0], vault1, "Should be vault1");

        vm.stopPrank();
    }

    /**
     * @dev Test unregister with zero address reverts
     */
    function test_Contract02_Case32_unregisterZeroAddressReverts() public {
        vm.startPrank(strategyAdmin);

        strategyRegistry.registerStrategy(
            StrategyRegistry.StrategyInput({
                id: STRATEGY_ID_1,
                adapter: adapter1,
                riskTier: RISK_LOW,
                maxTvl: 1_000_000e6,
                metadataHash: METADATA_HASH
            })
        );

        vm.expectRevert(abi.encodeWithSelector(StrategyRegistry.ZeroAddress.selector));
        strategyRegistry.unregisterStrategyVault(STRATEGY_ID_1, address(0));

        vm.stopPrank();
    }

    /**
     * @dev Test unregister from non-existent strategy reverts
     */
    function test_Contract02_Case33_unregisterFromNonExistentStrategyReverts() public {
        vm.prank(strategyAdmin);
        vm.expectRevert(abi.encodeWithSelector(StrategyRegistry.StrategyNotFound.selector, STRATEGY_ID_1));
        strategyRegistry.unregisterStrategyVault(STRATEGY_ID_1, vault1);
    }

    // ============================================
    // EDGE CASE TESTS
    // ============================================

    /**
     * @dev Test complete lifecycle flow
     */
    function test_Contract02_Case24_completeLifecycleFlow() public {
        vm.startPrank(strategyAdmin);

        // Register
        strategyRegistry.registerStrategy(
            StrategyRegistry.StrategyInput({
                id: STRATEGY_ID_1,
                adapter: adapter1,
                riskTier: RISK_LOW,
                maxTvl: 1_000_000e6,
                metadataHash: METADATA_HASH
            })
        );

        // Link vaults while Active
        strategyRegistry.registerStrategyVault(STRATEGY_ID_1, vault1);
        strategyRegistry.registerStrategyVault(STRATEGY_ID_1, vault2);

        // Fade out
        strategyRegistry.setStrategyStatus(STRATEGY_ID_1, GiveTypes.StrategyStatus.FadingOut);

        // Eventually deprecate
        strategyRegistry.setStrategyStatus(STRATEGY_ID_1, GiveTypes.StrategyStatus.Deprecated);

        vm.stopPrank();

        GiveTypes.StrategyConfig memory cfg = strategyRegistry.getStrategy(STRATEGY_ID_1);
        assertEq(uint256(cfg.status), uint256(GiveTypes.StrategyStatus.Deprecated), "Should be deprecated");

        address[] memory vaults = strategyRegistry.getStrategyVaults(STRATEGY_ID_1);
        assertEq(vaults.length, 2, "Vaults should still be linked");
    }
}
