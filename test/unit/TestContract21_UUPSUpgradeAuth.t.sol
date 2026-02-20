// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {ACLManager} from "../../src/governance/ACLManager.sol";
import {NGORegistry} from "../../src/donation/NGORegistry.sol";
import {CampaignVaultFactory} from "../../src/factory/CampaignVaultFactory.sol";
import {PayoutRouter} from "../../src/payout/PayoutRouter.sol";

contract TestContract21_UUPSUpgradeAuth is Test {
    ACLManager public aclManager;

    address public superAdmin;
    address public upgrader;
    address public unauthorized;

    function setUp() public {
        superAdmin = makeAddr("superAdmin");
        upgrader = makeAddr("upgrader");
        unauthorized = makeAddr("unauthorized");

        ACLManager aclImpl = new ACLManager();
        bytes memory aclInitData = abi.encodeWithSelector(ACLManager.initialize.selector, superAdmin, upgrader);
        aclManager = ACLManager(address(new ERC1967Proxy(address(aclImpl), aclInitData)));
    }

    function test_Contract21_Case01_ngoRegistry_upgradeRequiresRoleUpgrader() public {
        NGORegistry implementation = new NGORegistry();
        bytes memory initData = abi.encodeWithSelector(NGORegistry.initialize.selector, address(aclManager));
        NGORegistry proxy = NGORegistry(address(new ERC1967Proxy(address(implementation), initData)));

        NGORegistry newImpl = new NGORegistry();

        vm.expectRevert(abi.encodeWithSelector(NGORegistry.Unauthorized.selector, proxy.ROLE_UPGRADER(), unauthorized));
        vm.prank(unauthorized);
        proxy.upgradeToAndCall(address(newImpl), "");

        vm.prank(upgrader);
        proxy.upgradeToAndCall(address(newImpl), "");
    }

    function test_Contract21_Case02_campaignVaultFactory_upgradeRequiresRoleUpgrader() public {
        CampaignVaultFactory implementation = new CampaignVaultFactory();
        bytes memory initData = abi.encodeWithSelector(
            CampaignVaultFactory.initialize.selector,
            address(aclManager),
            makeAddr("campaignRegistry"),
            makeAddr("strategyRegistry"),
            makeAddr("payoutRouter"),
            makeAddr("vaultImplementation")
        );
        CampaignVaultFactory proxy = CampaignVaultFactory(address(new ERC1967Proxy(address(implementation), initData)));

        CampaignVaultFactory newImpl = new CampaignVaultFactory();

        vm.expectRevert(
            abi.encodeWithSelector(CampaignVaultFactory.Unauthorized.selector, proxy.ROLE_UPGRADER(), unauthorized)
        );
        vm.prank(unauthorized);
        proxy.upgradeToAndCall(address(newImpl), "");

        vm.prank(upgrader);
        proxy.upgradeToAndCall(address(newImpl), "");
    }

    function test_Contract21_Case03_payoutRouter_upgradeRequiresRoleUpgrader() public {
        PayoutRouter implementation = new PayoutRouter();
        bytes memory initData = abi.encodeWithSelector(
            PayoutRouter.initialize.selector,
            superAdmin,
            address(aclManager),
            makeAddr("campaignRegistry"),
            makeAddr("feeRecipient"),
            makeAddr("protocolTreasury"),
            250
        );
        PayoutRouter proxy = PayoutRouter(address(new ERC1967Proxy(address(implementation), initData)));

        PayoutRouter newImpl = new PayoutRouter();

        vm.expectRevert(abi.encodeWithSelector(PayoutRouter.Unauthorized.selector, proxy.ROLE_UPGRADER(), unauthorized));
        vm.prank(unauthorized);
        proxy.upgradeToAndCall(address(newImpl), "");

        vm.prank(upgrader);
        proxy.upgradeToAndCall(address(newImpl), "");
    }
}
