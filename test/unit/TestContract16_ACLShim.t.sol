// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {ACLShim} from "../../src/utils/ACLShim.sol";
import {ACLManager} from "../../src/governance/ACLManager.sol";
import {IACLManager} from "../../src/interfaces/IACLManager.sol";

/// @dev Minimal concrete contract that exposes ACLShim internals for testing
contract ConcreteShim is ACLShim {
    bytes32 public constant TEST_ROLE = keccak256("TEST_ROLE");

    constructor(address admin) {
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(TEST_ROLE, admin);
    }

    /// @dev Public wrapper so tests can trigger _checkRole via a state-changing call
    ///      (view functions can't be caught by vm.expectRevert in Forge)
    function requireRole(bytes32 role, address account) external {
        _checkRole(role, account);
    }
}

contract TestContract16_ACLShim is Test {
    ConcreteShim public shim;
    ACLManager public aclManager;
    address public admin;
    address public alice;

    function setUp() public {
        admin = makeAddr("admin");
        alice = makeAddr("alice");

        shim = new ConcreteShim(admin);

        // Deploy a real ACLManager via proxy
        ACLManager impl = new ACLManager();
        bytes memory initData = abi.encodeWithSelector(ACLManager.initialize.selector, admin, admin);
        ERC1967Proxy proxy = new ERC1967Proxy(address(impl), initData);
        aclManager = ACLManager(address(proxy));
    }

    // ─── setACLManager ───────────────────────────────────────────────────────

    function test_Contract16_Case01_setACLManager_updatesStateAndEmits() public {
        address newManager = address(aclManager);

        vm.prank(admin);
        vm.expectEmit(true, true, false, false);
        emit ACLShim.ACLManagerUpdated(address(0), newManager);
        shim.setACLManager(newManager);

        assertEq(address(shim.aclManager()), newManager);
    }

    function test_Contract16_Case02_setACLManager_nonAdminReverts() public {
        vm.prank(alice);
        vm.expectRevert();
        shim.setACLManager(address(aclManager));
    }

    // ─── _checkRole with no ACLManager ────────────────────────────────────────

    function test_Contract16_Case03_checkRole_noACLManager_fallsBackToLocal() public {
        // admin has TEST_ROLE locally, no ACLManager set → should pass
        bytes32 role = shim.TEST_ROLE();
        shim.requireRole(role, admin);
    }

    function test_Contract16_Case04_checkRole_noACLManager_missingRoleReverts() public {
        // alice has no local role and no ACLManager → should revert
        bytes32 role = shim.TEST_ROLE();
        vm.expectRevert();
        shim.requireRole(role, alice);
    }

    // ─── _checkRole with ACLManager set ───────────────────────────────────────

    function test_Contract16_Case05_checkRole_aclManagerGrantsRole_passesEvenWithoutLocal() public {
        // Wire in the ACLManager
        vm.prank(admin);
        shim.setACLManager(address(aclManager));

        // Grant TEST_ROLE to alice in the ACLManager (not in shim locally)
        vm.startPrank(admin);
        aclManager.createRole(shim.TEST_ROLE(), admin);
        aclManager.grantRole(shim.TEST_ROLE(), alice);
        vm.stopPrank();

        // alice has no local role in shim, but ACLManager grants it → should pass
        shim.requireRole(shim.TEST_ROLE(), alice);
    }

    function test_Contract16_Case06_checkRole_aclManagerMissingRoleFallsBackToLocal() public {
        vm.prank(admin);
        shim.setACLManager(address(aclManager));

        // ACLManager doesn't know about TEST_ROLE, no role for alice there either
        // alice has no local role → reverts via fallback to super._checkRole
        bytes32 role = shim.TEST_ROLE();
        vm.expectRevert();
        shim.requireRole(role, alice);
    }

    // ─── setACLManager(address(0)) disables delegation ────────────────────────

    function test_Contract16_Case07_setACLManagerZero_disablesDelegation() public {
        // First enable ACLManager
        vm.prank(admin);
        shim.setACLManager(address(aclManager));

        // Grant TEST_ROLE to alice in ACLManager
        vm.startPrank(admin);
        aclManager.createRole(shim.TEST_ROLE(), admin);
        aclManager.grantRole(shim.TEST_ROLE(), alice);
        vm.stopPrank();

        bytes32 role = shim.TEST_ROLE();

        // Alice passes while ACLManager is wired in
        shim.requireRole(role, alice);

        // Now disable by setting to zero
        vm.prank(admin);
        shim.setACLManager(address(0));

        // Alice no longer passes (no local role)
        vm.expectRevert();
        shim.requireRole(role, alice);
    }
}
