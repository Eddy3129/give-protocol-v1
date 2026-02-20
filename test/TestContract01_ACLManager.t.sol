// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test, console} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {ACLManager} from "../src/governance/ACLManager.sol";

/**
 * @title   TestContract01_ACLManager
 * @author  GIVE Labs
 * @notice  Comprehensive test suite for ACLManager contract
 * @dev     Tests role-based access control with dynamic role creation, two-step admin transfers,
 *          and UUPS upgradeability. Covers all 8 canonical protocol roles and edge cases.
 */
contract TestContract01_ACLManager is Test {
    ACLManager public aclManager;
    ACLManager public implementation;
    ERC1967Proxy public proxy;

    address public superAdmin;
    address public upgrader;
    address public user1;
    address public user2;
    address public user3;

    bytes32 public constant ROLE_SUPER_ADMIN = keccak256("ROLE_SUPER_ADMIN");
    bytes32 public constant ROLE_UPGRADER = keccak256("ROLE_UPGRADER");
    bytes32 public constant ROLE_PROTOCOL_ADMIN = keccak256("ROLE_PROTOCOL_ADMIN");
    bytes32 public constant ROLE_STRATEGY_ADMIN = keccak256("ROLE_STRATEGY_ADMIN");
    bytes32 public constant ROLE_CAMPAIGN_ADMIN = keccak256("ROLE_CAMPAIGN_ADMIN");
    bytes32 public constant ROLE_CAMPAIGN_CREATOR = keccak256("ROLE_CAMPAIGN_CREATOR");
    bytes32 public constant ROLE_CAMPAIGN_CURATOR = keccak256("ROLE_CAMPAIGN_CURATOR");
    bytes32 public constant ROLE_CHECKPOINT_COUNCIL = keccak256("ROLE_CHECKPOINT_COUNCIL");

    bytes32 public constant CUSTOM_ROLE = keccak256("CUSTOM_ROLE");

    event RoleCreated(bytes32 indexed roleId, address indexed admin, address indexed creator);
    event RoleGranted(bytes32 indexed roleId, address indexed account, address indexed sender);
    event RoleRevoked(bytes32 indexed roleId, address indexed account, address indexed sender);
    event RoleAdminProposed(bytes32 indexed roleId, address indexed currentAdmin, address indexed proposedAdmin);
    event RoleAdminAccepted(bytes32 indexed roleId, address indexed previousAdmin, address indexed newAdmin);

    function setUp() public {
        superAdmin = address(this);
        upgrader = address(0x1);
        user1 = address(0x2);
        user2 = address(0x3);
        user3 = address(0x4);

        // Deploy implementation
        implementation = new ACLManager();

        // Deploy proxy
        bytes memory initData = abi.encodeWithSelector(ACLManager.initialize.selector, superAdmin, upgrader);
        proxy = new ERC1967Proxy(address(implementation), initData);
        aclManager = ACLManager(address(proxy));

        console.log("ACLManager proxy deployed at:", address(aclManager));
        console.log("Implementation deployed at:", address(implementation));
        console.log("Super admin address:", superAdmin);
        console.log("Upgrader address:", upgrader);
    }

    // ============================================
    // INITIALIZATION TESTS
    // ============================================

    /**
     * @dev Test initial deployment state and canonical roles
     */
    function test_Contract01_Case01_initializationState() public {
        // Verify super admin has ROLE_SUPER_ADMIN
        assertTrue(aclManager.hasRole(ROLE_SUPER_ADMIN, superAdmin), "Super admin should have ROLE_SUPER_ADMIN");

        // Verify upgrader has ROLE_UPGRADER
        assertTrue(aclManager.hasRole(ROLE_UPGRADER, upgrader), "Upgrader should have ROLE_UPGRADER");

        // Verify all canonical roles exist
        assertTrue(aclManager.roleExists(ROLE_SUPER_ADMIN), "ROLE_SUPER_ADMIN should exist");
        assertTrue(aclManager.roleExists(ROLE_UPGRADER), "ROLE_UPGRADER should exist");
        assertTrue(aclManager.roleExists(ROLE_PROTOCOL_ADMIN), "ROLE_PROTOCOL_ADMIN should exist");
        assertTrue(aclManager.roleExists(ROLE_STRATEGY_ADMIN), "ROLE_STRATEGY_ADMIN should exist");
        assertTrue(aclManager.roleExists(ROLE_CAMPAIGN_ADMIN), "ROLE_CAMPAIGN_ADMIN should exist");
        assertTrue(aclManager.roleExists(ROLE_CAMPAIGN_CREATOR), "ROLE_CAMPAIGN_CREATOR should exist");
        assertTrue(aclManager.roleExists(ROLE_CAMPAIGN_CURATOR), "ROLE_CAMPAIGN_CURATOR should exist");
        assertTrue(aclManager.roleExists(ROLE_CHECKPOINT_COUNCIL), "ROLE_CHECKPOINT_COUNCIL should exist");

        // Verify super admin has all canonical roles
        assertTrue(aclManager.hasRole(ROLE_PROTOCOL_ADMIN, superAdmin), "Super admin should have ROLE_PROTOCOL_ADMIN");
        assertTrue(aclManager.hasRole(ROLE_STRATEGY_ADMIN, superAdmin), "Super admin should have ROLE_STRATEGY_ADMIN");
        assertTrue(aclManager.hasRole(ROLE_CAMPAIGN_ADMIN, superAdmin), "Super admin should have ROLE_CAMPAIGN_ADMIN");
        assertTrue(
            aclManager.hasRole(ROLE_CAMPAIGN_CREATOR, superAdmin), "Super admin should have ROLE_CAMPAIGN_CREATOR"
        );
        assertTrue(
            aclManager.hasRole(ROLE_CAMPAIGN_CURATOR, superAdmin), "Super admin should have ROLE_CAMPAIGN_CURATOR"
        );
        assertTrue(
            aclManager.hasRole(ROLE_CHECKPOINT_COUNCIL, superAdmin), "Super admin should have ROLE_CHECKPOINT_COUNCIL"
        );
    }

    /**
     * @dev Test that initialize cannot be called twice
     */
    function test_Contract01_Case02_cannotReinitialize() public {
        vm.expectRevert();
        aclManager.initialize(user1, user2);
    }

    /**
     * @dev Test that initialize reverts on zero addresses
     */
    function test_Contract01_Case03_initializeZeroAddressReverts() public {
        ACLManager newImpl = new ACLManager();

        // Zero super admin
        bytes memory initData1 = abi.encodeWithSelector(ACLManager.initialize.selector, address(0), upgrader);
        vm.expectRevert(ACLManager.ZeroAddress.selector);
        new ERC1967Proxy(address(newImpl), initData1);

        // Zero upgrader
        bytes memory initData2 = abi.encodeWithSelector(ACLManager.initialize.selector, superAdmin, address(0));
        vm.expectRevert(ACLManager.ZeroAddress.selector);
        new ERC1967Proxy(address(newImpl), initData2);
    }

    // ============================================
    // ROLE CREATION TESTS
    // ============================================

    /**
     * @dev Test creating a new custom role
     */
    function test_Contract01_Case04_createRole() public {
        vm.expectEmit(true, true, true, true);
        emit RoleCreated(CUSTOM_ROLE, superAdmin, superAdmin);
        aclManager.createRole(CUSTOM_ROLE, superAdmin);

        assertTrue(aclManager.roleExists(CUSTOM_ROLE), "Custom role should exist");
        assertEq(aclManager.roleAdmin(CUSTOM_ROLE), superAdmin, "Super admin should be role admin");
    }

    /**
     * @dev Test that only super admin can create roles
     */
    function test_Contract01_Case05_onlySuperAdminCanCreateRole() public {
        vm.prank(user1);
        vm.expectRevert(abi.encodeWithSelector(ACLManager.UnauthorizedRole.selector, ROLE_SUPER_ADMIN, user1));
        aclManager.createRole(CUSTOM_ROLE, superAdmin);
    }

    /**
     * @dev Test that role admin must be super admin
     */
    function test_Contract01_Case06_roleAdminMustBeSuperAdmin() public {
        vm.expectRevert(abi.encodeWithSelector(ACLManager.AdminMustBeSuper.selector, CUSTOM_ROLE, user1));
        aclManager.createRole(CUSTOM_ROLE, user1);
    }

    /**
     * @dev Test that duplicate roles cannot be created
     */
    function test_Contract01_Case07_cannotCreateDuplicateRole() public {
        aclManager.createRole(CUSTOM_ROLE, superAdmin);

        vm.expectRevert(abi.encodeWithSelector(ACLManager.RoleAlreadyExists.selector, CUSTOM_ROLE));
        aclManager.createRole(CUSTOM_ROLE, superAdmin);
    }

    /**
     * @dev Test creating role with zero address reverts
     */
    function test_Contract01_Case08_createRoleZeroAddressReverts() public {
        vm.expectRevert(ACLManager.ZeroAddress.selector);
        aclManager.createRole(CUSTOM_ROLE, address(0));
    }

    // ============================================
    // GRANT/REVOKE ROLE TESTS
    // ============================================

    /**
     * @dev Test granting a role to an account
     */
    function test_Contract01_Case09_grantRole() public {
        aclManager.createRole(CUSTOM_ROLE, superAdmin);

        vm.expectEmit(true, true, true, true);
        emit RoleGranted(CUSTOM_ROLE, user1, superAdmin);
        aclManager.grantRole(CUSTOM_ROLE, user1);

        assertTrue(aclManager.hasRole(CUSTOM_ROLE, user1), "User1 should have custom role");

        address[] memory members = aclManager.getRoleMembers(CUSTOM_ROLE);
        assertEq(members.length, 1, "Should have 1 member");
        assertEq(members[0], user1, "First member should be user1");
    }

    /**
     * @dev Test revoking a role from an account
     */
    function test_Contract01_Case10_revokeRole() public {
        aclManager.createRole(CUSTOM_ROLE, superAdmin);
        aclManager.grantRole(CUSTOM_ROLE, user1);

        vm.expectEmit(true, true, true, true);
        emit RoleRevoked(CUSTOM_ROLE, user1, superAdmin);
        aclManager.revokeRole(CUSTOM_ROLE, user1);

        assertFalse(aclManager.hasRole(CUSTOM_ROLE, user1), "User1 should not have custom role");

        address[] memory members = aclManager.getRoleMembers(CUSTOM_ROLE);
        assertEq(members.length, 0, "Should have 0 members");
    }

    /**
     * @dev Test that only role admin can grant/revoke
     */
    function test_Contract01_Case11_onlyRoleAdminCanGrantRevoke() public {
        aclManager.createRole(CUSTOM_ROLE, superAdmin);

        vm.startPrank(user1);
        vm.expectRevert(abi.encodeWithSelector(ACLManager.UnauthorizedRole.selector, CUSTOM_ROLE, user1));
        aclManager.grantRole(CUSTOM_ROLE, user2);

        vm.expectRevert(abi.encodeWithSelector(ACLManager.UnauthorizedRole.selector, CUSTOM_ROLE, user1));
        aclManager.revokeRole(CUSTOM_ROLE, user2);
        vm.stopPrank();
    }

    /**
     * @dev Test granting role to zero address reverts
     */
    function test_Contract01_Case12_grantRoleZeroAddressReverts() public {
        aclManager.createRole(CUSTOM_ROLE, superAdmin);

        vm.expectRevert(ACLManager.ZeroAddress.selector);
        aclManager.grantRole(CUSTOM_ROLE, address(0));
    }

    /**
     * @dev Test revoking role from zero address reverts
     */
    function test_Contract01_Case13_revokeRoleZeroAddressReverts() public {
        aclManager.createRole(CUSTOM_ROLE, superAdmin);

        vm.expectRevert(ACLManager.ZeroAddress.selector);
        aclManager.revokeRole(CUSTOM_ROLE, address(0));
    }

    /**
     * @dev Test granting non-existent role reverts
     */
    function test_Contract01_Case14_grantNonExistentRoleReverts() public {
        vm.expectRevert(abi.encodeWithSelector(ACLManager.RoleDoesNotExist.selector, CUSTOM_ROLE));
        aclManager.grantRole(CUSTOM_ROLE, user1);
    }

    /**
     * @dev Test revoking non-existent role reverts
     */
    function test_Contract01_Case15_revokeNonExistentRoleReverts() public {
        vm.expectRevert(abi.encodeWithSelector(ACLManager.RoleDoesNotExist.selector, CUSTOM_ROLE));
        aclManager.revokeRole(CUSTOM_ROLE, user1);
    }

    /**
     * @dev Test that grant/revoke are idempotent
     */
    function test_Contract01_Case16_grantRevokeIdempotent() public {
        aclManager.createRole(CUSTOM_ROLE, superAdmin);

        // Grant twice - should not revert
        aclManager.grantRole(CUSTOM_ROLE, user1);
        aclManager.grantRole(CUSTOM_ROLE, user1);

        address[] memory members = aclManager.getRoleMembers(CUSTOM_ROLE);
        assertEq(members.length, 1, "Should have 1 member (not 2)");

        // Revoke twice - should not revert
        aclManager.revokeRole(CUSTOM_ROLE, user1);
        aclManager.revokeRole(CUSTOM_ROLE, user1);

        assertFalse(aclManager.hasRole(CUSTOM_ROLE, user1), "User1 should not have role");
    }

    /**
     * @dev Test swap-and-pop enumeration with multiple members
     */
    function test_Contract01_Case17_swapAndPopEnumeration() public {
        aclManager.createRole(CUSTOM_ROLE, superAdmin);

        // Grant to multiple users
        aclManager.grantRole(CUSTOM_ROLE, user1);
        aclManager.grantRole(CUSTOM_ROLE, user2);
        aclManager.grantRole(CUSTOM_ROLE, user3);

        address[] memory members = aclManager.getRoleMembers(CUSTOM_ROLE);
        assertEq(members.length, 3, "Should have 3 members");

        // Revoke from middle
        aclManager.revokeRole(CUSTOM_ROLE, user2);

        members = aclManager.getRoleMembers(CUSTOM_ROLE);
        assertEq(members.length, 2, "Should have 2 members after revoke");

        // Verify user2 no longer has role
        assertFalse(aclManager.hasRole(CUSTOM_ROLE, user2), "User2 should not have role");

        // Verify user1 and user3 still have role
        assertTrue(aclManager.hasRole(CUSTOM_ROLE, user1), "User1 should still have role");
        assertTrue(aclManager.hasRole(CUSTOM_ROLE, user3), "User3 should still have role");
    }

    // ============================================
    // TWO-STEP ADMIN TRANSFER TESTS
    // ============================================

    /**
     * @dev Test proposing a new role admin
     */
    function test_Contract01_Case18_proposeRoleAdmin() public {
        aclManager.createRole(CUSTOM_ROLE, superAdmin);

        // Grant super admin to user1
        aclManager.grantRole(ROLE_SUPER_ADMIN, user1);

        vm.expectEmit(true, true, true, true);
        emit RoleAdminProposed(CUSTOM_ROLE, superAdmin, user1);
        aclManager.proposeRoleAdmin(CUSTOM_ROLE, user1);
    }

    /**
     * @dev Test accepting role admin transfer
     */
    function test_Contract01_Case19_acceptRoleAdmin() public {
        aclManager.createRole(CUSTOM_ROLE, superAdmin);

        // Grant super admin to user1
        aclManager.grantRole(ROLE_SUPER_ADMIN, user1);

        // Propose user1 as new admin
        aclManager.proposeRoleAdmin(CUSTOM_ROLE, user1);

        // User1 accepts
        vm.prank(user1);
        vm.expectEmit(true, true, true, true);
        emit RoleAdminAccepted(CUSTOM_ROLE, superAdmin, user1);
        aclManager.acceptRoleAdmin(CUSTOM_ROLE);

        assertEq(aclManager.roleAdmin(CUSTOM_ROLE), user1, "User1 should be new admin");
    }

    /**
     * @dev Test that only pending admin can accept
     */
    function test_Contract01_Case20_onlyPendingAdminCanAccept() public {
        aclManager.createRole(CUSTOM_ROLE, superAdmin);
        aclManager.grantRole(ROLE_SUPER_ADMIN, user1);
        aclManager.proposeRoleAdmin(CUSTOM_ROLE, user1);

        // User2 tries to accept
        vm.prank(user2);
        vm.expectRevert(abi.encodeWithSelector(ACLManager.PendingAdminMismatch.selector, CUSTOM_ROLE, user1, user2));
        aclManager.acceptRoleAdmin(CUSTOM_ROLE);
    }

    /**
     * @dev Test accepting without proposal reverts
     */
    function test_Contract01_Case21_acceptWithoutProposalReverts() public {
        aclManager.createRole(CUSTOM_ROLE, superAdmin);

        vm.prank(user1);
        vm.expectRevert(abi.encodeWithSelector(ACLManager.PendingAdminMissing.selector, CUSTOM_ROLE));
        aclManager.acceptRoleAdmin(CUSTOM_ROLE);
    }

    /**
     * @dev Test proposing zero address reverts
     */
    function test_Contract01_Case22_proposeZeroAddressReverts() public {
        aclManager.createRole(CUSTOM_ROLE, superAdmin);

        vm.expectRevert(ACLManager.ZeroAddress.selector);
        aclManager.proposeRoleAdmin(CUSTOM_ROLE, address(0));
    }

    /**
     * @dev Test new admin must be super admin
     */
    function test_Contract01_Case23_newAdminMustBeSuperAdmin() public {
        aclManager.createRole(CUSTOM_ROLE, superAdmin);

        vm.expectRevert(abi.encodeWithSelector(ACLManager.AdminMustBeSuper.selector, CUSTOM_ROLE, user1));
        aclManager.proposeRoleAdmin(CUSTOM_ROLE, user1);
    }

    /**
     * @dev Test accepting admin must have super admin role
     */
    function test_Contract01_Case24_acceptingAdminMustBeSuperAdmin() public {
        aclManager.createRole(CUSTOM_ROLE, superAdmin);

        // Temporarily grant super admin to user1
        aclManager.grantRole(ROLE_SUPER_ADMIN, user1);
        aclManager.proposeRoleAdmin(CUSTOM_ROLE, user1);

        // Revoke super admin before accepting
        aclManager.revokeRole(ROLE_SUPER_ADMIN, user1);

        vm.prank(user1);
        vm.expectRevert(abi.encodeWithSelector(ACLManager.AdminMustBeSuper.selector, CUSTOM_ROLE, user1));
        aclManager.acceptRoleAdmin(CUSTOM_ROLE);
    }

    /**
     * @dev Test that new admin can manage role after transfer
     */
    function test_Contract01_Case25_newAdminCanManageRole() public {
        aclManager.createRole(CUSTOM_ROLE, superAdmin);

        // Transfer admin to user1
        aclManager.grantRole(ROLE_SUPER_ADMIN, user1);
        aclManager.proposeRoleAdmin(CUSTOM_ROLE, user1);
        vm.prank(user1);
        aclManager.acceptRoleAdmin(CUSTOM_ROLE);

        // User1 can now grant role
        vm.prank(user1);
        aclManager.grantRole(CUSTOM_ROLE, user2);

        assertTrue(aclManager.hasRole(CUSTOM_ROLE, user2), "User2 should have role");
    }

    // ============================================
    // VIEW FUNCTION TESTS
    // ============================================

    /**
     * @dev Test hasRole for existing and non-existing roles
     */
    function test_Contract01_Case26_hasRole() public {
        aclManager.createRole(CUSTOM_ROLE, superAdmin);
        aclManager.grantRole(CUSTOM_ROLE, user1);

        assertTrue(aclManager.hasRole(CUSTOM_ROLE, user1), "User1 should have role");
        assertFalse(aclManager.hasRole(CUSTOM_ROLE, user2), "User2 should not have role");

        // Non-existent role
        bytes32 fakeRole = keccak256("FAKE_ROLE");
        assertFalse(aclManager.hasRole(fakeRole, user1), "Should return false for non-existent role");
    }

    /**
     * @dev Test roleAdmin getter
     */
    function test_Contract01_Case27_roleAdmin() public {
        aclManager.createRole(CUSTOM_ROLE, superAdmin);

        assertEq(aclManager.roleAdmin(CUSTOM_ROLE), superAdmin, "Should return correct admin");

        // Non-existent role
        bytes32 fakeRole = keccak256("FAKE_ROLE");
        assertEq(aclManager.roleAdmin(fakeRole), address(0), "Should return zero for non-existent role");
    }

    /**
     * @dev Test getRoleMembers
     */
    function test_Contract01_Case28_getRoleMembers() public {
        aclManager.createRole(CUSTOM_ROLE, superAdmin);
        aclManager.grantRole(CUSTOM_ROLE, user1);
        aclManager.grantRole(CUSTOM_ROLE, user2);

        address[] memory members = aclManager.getRoleMembers(CUSTOM_ROLE);
        assertEq(members.length, 2, "Should have 2 members");
        assertTrue(members[0] == user1 || members[0] == user2, "Member should be user1 or user2");
        assertTrue(members[1] == user1 || members[1] == user2, "Member should be user1 or user2");
    }

    /**
     * @dev Test getRoleMembers reverts for non-existent role
     */
    function test_Contract01_Case29_getRoleMembersNonExistentReverts() public {
        vm.expectRevert(abi.encodeWithSelector(ACLManager.RoleDoesNotExist.selector, CUSTOM_ROLE));
        aclManager.getRoleMembers(CUSTOM_ROLE);
    }

    /**
     * @dev Test roleExists
     */
    function test_Contract01_Case30_roleExists() public {
        assertFalse(aclManager.roleExists(CUSTOM_ROLE), "Custom role should not exist");

        aclManager.createRole(CUSTOM_ROLE, superAdmin);

        assertTrue(aclManager.roleExists(CUSTOM_ROLE), "Custom role should exist");
    }

    // ============================================
    // CANONICAL ROLES TESTS
    // ============================================

    /**
     * @dev Test canonicalRoles returns all 8 roles
     */
    function test_Contract01_Case31_canonicalRoles() public {
        bytes32[] memory roles = aclManager.canonicalRoles();

        assertEq(roles.length, 8, "Should have 8 canonical roles");
        assertEq(roles[0], ROLE_SUPER_ADMIN, "Role 0 should be SUPER_ADMIN");
        assertEq(roles[1], ROLE_UPGRADER, "Role 1 should be UPGRADER");
        assertEq(roles[2], ROLE_PROTOCOL_ADMIN, "Role 2 should be PROTOCOL_ADMIN");
        assertEq(roles[3], ROLE_STRATEGY_ADMIN, "Role 3 should be STRATEGY_ADMIN");
        assertEq(roles[4], ROLE_CAMPAIGN_ADMIN, "Role 4 should be CAMPAIGN_ADMIN");
        assertEq(roles[5], ROLE_CAMPAIGN_CREATOR, "Role 5 should be CAMPAIGN_CREATOR");
        assertEq(roles[6], ROLE_CAMPAIGN_CURATOR, "Role 6 should be CAMPAIGN_CURATOR");
        assertEq(roles[7], ROLE_CHECKPOINT_COUNCIL, "Role 7 should be CHECKPOINT_COUNCIL");
    }

    /**
     * @dev Test isCanonicalRole
     */
    function test_Contract01_Case32_isCanonicalRole() public {
        assertTrue(aclManager.isCanonicalRole(ROLE_SUPER_ADMIN), "SUPER_ADMIN should be canonical");
        assertTrue(aclManager.isCanonicalRole(ROLE_UPGRADER), "UPGRADER should be canonical");
        assertTrue(aclManager.isCanonicalRole(ROLE_PROTOCOL_ADMIN), "PROTOCOL_ADMIN should be canonical");
        assertTrue(aclManager.isCanonicalRole(ROLE_STRATEGY_ADMIN), "STRATEGY_ADMIN should be canonical");
        assertTrue(aclManager.isCanonicalRole(ROLE_CAMPAIGN_ADMIN), "CAMPAIGN_ADMIN should be canonical");
        assertTrue(aclManager.isCanonicalRole(ROLE_CAMPAIGN_CREATOR), "CAMPAIGN_CREATOR should be canonical");
        assertTrue(aclManager.isCanonicalRole(ROLE_CAMPAIGN_CURATOR), "CAMPAIGN_CURATOR should be canonical");
        assertTrue(aclManager.isCanonicalRole(ROLE_CHECKPOINT_COUNCIL), "CHECKPOINT_COUNCIL should be canonical");

        assertFalse(aclManager.isCanonicalRole(CUSTOM_ROLE), "CUSTOM_ROLE should not be canonical");
    }

    /**
     * @dev Test canonical role getters
     */
    function test_Contract01_Case33_canonicalRoleGetters() public {
        assertEq(aclManager.protocolAdminRole(), ROLE_PROTOCOL_ADMIN, "protocolAdminRole should match");
        assertEq(aclManager.strategyAdminRole(), ROLE_STRATEGY_ADMIN, "strategyAdminRole should match");
        assertEq(aclManager.campaignAdminRole(), ROLE_CAMPAIGN_ADMIN, "campaignAdminRole should match");
        assertEq(aclManager.campaignCreatorRole(), ROLE_CAMPAIGN_CREATOR, "campaignCreatorRole should match");
        assertEq(aclManager.campaignCuratorRole(), ROLE_CAMPAIGN_CURATOR, "campaignCuratorRole should match");
        assertEq(aclManager.checkpointCouncilRole(), ROLE_CHECKPOINT_COUNCIL, "checkpointCouncilRole should match");
    }

    // ============================================
    // UUPS UPGRADE TESTS
    // ============================================

    /**
     * @dev Test that only upgrader can upgrade
     */
    function test_Contract01_Case34_onlyUpgraderCanUpgrade() public {
        ACLManager newImpl = new ACLManager();

        // Upgrader can upgrade
        vm.prank(upgrader);
        aclManager.upgradeToAndCall(address(newImpl), "");

        // Non-upgrader cannot upgrade
        ACLManager newerImpl = new ACLManager();
        vm.prank(user1);
        vm.expectRevert(abi.encodeWithSelector(ACLManager.UnauthorizedRole.selector, ROLE_UPGRADER, user1));
        aclManager.upgradeToAndCall(address(newerImpl), "");
    }

    /**
     * @dev Test that state persists after upgrade
     */
    function test_Contract01_Case35_statePersistsAfterUpgrade() public {
        // Create custom role and grant to user1
        aclManager.createRole(CUSTOM_ROLE, superAdmin);
        aclManager.grantRole(CUSTOM_ROLE, user1);

        // Upgrade
        ACLManager newImpl = new ACLManager();
        vm.prank(upgrader);
        aclManager.upgradeToAndCall(address(newImpl), "");

        // Verify state persisted
        assertTrue(aclManager.hasRole(CUSTOM_ROLE, user1), "State should persist after upgrade");
        assertTrue(aclManager.hasRole(ROLE_SUPER_ADMIN, superAdmin), "Super admin role should persist");
    }

    // ============================================
    // SUPER ADMIN OVERRIDE TESTS
    // ============================================

    /**
     * @dev Test that super admin can override role admins
     */
    function test_Contract01_Case36_superAdminCanOverride() public {
        // Create custom role with user1 as admin
        aclManager.grantRole(ROLE_SUPER_ADMIN, user1);
        vm.prank(user1);
        aclManager.createRole(CUSTOM_ROLE, user1);

        // Super admin can still grant/revoke even though user1 is admin
        aclManager.grantRole(CUSTOM_ROLE, user2);
        assertTrue(aclManager.hasRole(CUSTOM_ROLE, user2), "Super admin should be able to grant");

        aclManager.revokeRole(CUSTOM_ROLE, user2);
        assertFalse(aclManager.hasRole(CUSTOM_ROLE, user2), "Super admin should be able to revoke");
    }

    // ============================================
    // EDGE CASE TESTS
    // ============================================

    /**
     * @dev Test accepting role admin for non-existent role
     */
    function test_Contract01_Case37_acceptNonExistentRoleReverts() public {
        vm.prank(user1);
        vm.expectRevert(abi.encodeWithSelector(ACLManager.RoleDoesNotExist.selector, CUSTOM_ROLE));
        aclManager.acceptRoleAdmin(CUSTOM_ROLE);
    }

    /**
     * @dev Test proposing admin for role caller doesn't admin
     */
    function test_Contract01_Case38_proposeForRoleNotAdminReverts() public {
        aclManager.createRole(CUSTOM_ROLE, superAdmin);

        vm.prank(user1);
        vm.expectRevert(abi.encodeWithSelector(ACLManager.UnauthorizedRole.selector, CUSTOM_ROLE, user1));
        aclManager.proposeRoleAdmin(CUSTOM_ROLE, user2);
    }

    /**
     * @dev Test granting role on non-existent role
     */
    function test_Contract01_Case39_grantOnNonExistentRoleReverts() public {
        vm.expectRevert(abi.encodeWithSelector(ACLManager.RoleDoesNotExist.selector, CUSTOM_ROLE));
        aclManager.grantRole(CUSTOM_ROLE, user1);
    }

    /**
     * @dev Test multiple sequential admin transfers
     */
    function test_Contract01_Case40_multipleAdminTransfers() public {
        aclManager.createRole(CUSTOM_ROLE, superAdmin);

        // Transfer to user1
        aclManager.grantRole(ROLE_SUPER_ADMIN, user1);
        aclManager.proposeRoleAdmin(CUSTOM_ROLE, user1);
        vm.prank(user1);
        aclManager.acceptRoleAdmin(CUSTOM_ROLE);
        assertEq(aclManager.roleAdmin(CUSTOM_ROLE), user1, "Admin should be user1");

        // Transfer to user2
        aclManager.grantRole(ROLE_SUPER_ADMIN, user2);
        vm.prank(user1);
        aclManager.proposeRoleAdmin(CUSTOM_ROLE, user2);
        vm.prank(user2);
        aclManager.acceptRoleAdmin(CUSTOM_ROLE);
        assertEq(aclManager.roleAdmin(CUSTOM_ROLE), user2, "Admin should be user2");

        // Transfer back to superAdmin
        vm.prank(user2);
        aclManager.proposeRoleAdmin(CUSTOM_ROLE, superAdmin);
        aclManager.acceptRoleAdmin(CUSTOM_ROLE);
        assertEq(aclManager.roleAdmin(CUSTOM_ROLE), superAdmin, "Admin should be superAdmin");
    }
}
