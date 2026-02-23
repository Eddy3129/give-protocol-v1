// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title   ForkTest11_UpgradeCriticalPaths
 * @author  GIVE Labs
 * @notice  High-value fork upgrade checks for critical protocol paths
 * @dev     Focused fork scope (non-duplicative with unit upgrade auth matrix):
 *          - PayoutRouter UUPS auth + state preservation + post-upgrade behavior
 *          - GiveVault4626 UUPS auth + state preservation on a live Base asset
 *          - Adapter architecture guard: AaveAdapter is intentionally non-upgradeable
 */

import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {ForkBase} from "./ForkBase.t.sol";
import {ForkAddresses} from "./ForkAddresses.sol";
import {ForkHelperConfig} from "./ForkHelperConfig.sol";
import {ACLManager} from "../../src/governance/ACLManager.sol";
import {StrategyRegistry} from "../../src/registry/StrategyRegistry.sol";
import {CampaignRegistry} from "../../src/registry/CampaignRegistry.sol";
import {GiveVault4626} from "../../src/vault/GiveVault4626.sol";
import {AaveAdapter} from "../../src/adapters/AaveAdapter.sol";
import {PayoutRouter} from "../../src/payout/PayoutRouter.sol";

contract PayoutRouterV2Harness is PayoutRouter {
    function version() external pure returns (uint256) {
        return 2;
    }
}

contract GiveVault4626V2Harness is GiveVault4626 {
    function version() external pure returns (uint256) {
        return 2;
    }
}

contract ForkTest11_UpgradeCriticalPaths is ForkBase {
    bytes32 internal constant ROLE_UPGRADER = keccak256("ROLE_UPGRADER");

    ACLManager internal acl;
    StrategyRegistry internal strategyRegistry;
    CampaignRegistry internal campaignRegistry;
    GiveVault4626 internal vault;
    PayoutRouter internal router;

    address internal admin;
    address internal upgrader;
    address internal unauthorized;
    address internal feeRecipient;
    address internal protocolTreasury;

    function setUp() public override {
        super.setUp();
        if (!_forkActive) return;

        admin = makeAddr("f11_admin");
        upgrader = makeAddr("f11_upgrader");
        unauthorized = makeAddr("f11_unauthorized");
        feeRecipient = makeAddr("f11_fee_recipient");
        protocolTreasury = makeAddr("f11_treasury");

        ForkHelperConfig.RegistrySuite memory suite = ForkHelperConfig.initAllRegistries(admin);
        acl = suite.acl;
        strategyRegistry = suite.strategyRegistry;
        campaignRegistry = suite.campaignRegistry;

        vm.startPrank(admin);
        ForkHelperConfig.grantCoreProtocolRoles(acl, admin, address(0));
        ForkHelperConfig.grantNgoRegistryRoles(acl, admin, address(0));
        vm.stopPrank();

        GiveVault4626 vaultImpl = new GiveVault4626();
        vault = GiveVault4626(
            payable(address(
                    new ERC1967Proxy(
                        address(vaultImpl),
                        abi.encodeWithSelector(
                            GiveVault4626.initialize.selector,
                            ForkAddresses.USDC,
                            "Fork11 Vault",
                            "f11VAULT",
                            admin,
                            address(acl),
                            address(vaultImpl)
                        )
                    )
                ))
        );

        PayoutRouter implementation = new PayoutRouter();
        bytes memory initData = abi.encodeWithSelector(
            PayoutRouter.initialize.selector,
            admin,
            address(acl),
            address(campaignRegistry),
            feeRecipient,
            protocolTreasury,
            250
        );
        router = PayoutRouter(address(new ERC1967Proxy(address(implementation), initData)));

        vm.prank(admin);
        acl.grantRole(ROLE_UPGRADER, upgrader);
    }

    function test_upgrade_requires_role_upgrader_payoutRouter() public requiresFork {
        PayoutRouterV2Harness newImpl = new PayoutRouterV2Harness();

        vm.expectRevert(
            abi.encodeWithSelector(PayoutRouter.Unauthorized.selector, router.ROLE_UPGRADER(), unauthorized)
        );
        vm.prank(unauthorized);
        router.upgradeToAndCall(address(newImpl), "");
    }

    function test_upgrade_preserves_state_and_behavior_payoutRouter() public requiresFork {
        address oldCampaignRegistry = router.campaignRegistry();
        address oldFeeRecipient = router.feeRecipient();
        address oldProtocolTreasury = router.protocolTreasury();
        uint256 oldFeeBps = router.feeBps();

        PayoutRouterV2Harness newImpl = new PayoutRouterV2Harness();

        vm.prank(upgrader);
        router.upgradeToAndCall(address(newImpl), "");

        PayoutRouterV2Harness upgraded = PayoutRouterV2Harness(address(router));

        assertEq(upgraded.version(), 2, "implementation not upgraded");
        assertEq(upgraded.campaignRegistry(), oldCampaignRegistry, "campaign registry changed");
        assertEq(upgraded.feeRecipient(), oldFeeRecipient, "fee recipient changed");
        assertEq(upgraded.protocolTreasury(), oldProtocolTreasury, "protocol treasury changed");
        assertEq(upgraded.feeBps(), oldFeeBps, "fee bps changed");

        vm.startPrank(admin);
        upgraded.grantRole(upgraded.FEE_MANAGER_ROLE(), admin);
        upgraded.proposeFeeChange(oldFeeRecipient, oldFeeBps - 50);
        vm.stopPrank();

        assertEq(upgraded.feeBps(), oldFeeBps - 50, "post-upgrade fee change failed");
    }

    function test_upgrade_requires_role_upgrader_vault() public requiresFork {
        GiveVault4626V2Harness newImpl = new GiveVault4626V2Harness();

        vm.expectRevert(
            abi.encodeWithSelector(GiveVault4626.Unauthorized.selector, vault.ROLE_UPGRADER(), unauthorized)
        );
        vm.prank(unauthorized);
        vault.upgradeToAndCall(address(newImpl), "");
    }

    function test_upgrade_preserves_state_vault() public requiresFork {
        address oldAsset = vault.asset();
        uint256 oldCashBufferBps = vault.cashBufferBps();
        uint256 oldSlippageBps = vault.slippageBps();
        uint256 oldMaxLossBps = vault.maxLossBps();

        GiveVault4626V2Harness newImpl = new GiveVault4626V2Harness();
        vm.prank(upgrader);
        vault.upgradeToAndCall(address(newImpl), "");

        GiveVault4626V2Harness upgraded = GiveVault4626V2Harness(payable(address(vault)));
        assertEq(upgraded.version(), 2, "implementation not upgraded");
        assertEq(upgraded.asset(), oldAsset, "asset changed");
        assertEq(upgraded.cashBufferBps(), oldCashBufferBps, "cash buffer changed");
        assertEq(upgraded.slippageBps(), oldSlippageBps, "slippage changed");
        assertEq(upgraded.maxLossBps(), oldMaxLossBps, "max loss changed");
    }

    function test_adapter_is_not_upgradeable() public requiresFork {
        AaveAdapter adapter = new AaveAdapter(ForkAddresses.USDC, address(vault), ForkAddresses.AAVE_POOL, admin);
        GiveVault4626V2Harness newImpl = new GiveVault4626V2Harness();

        (bool success,) = address(adapter)
            .call(abi.encodeWithSignature("upgradeToAndCall(address,bytes)", address(newImpl), bytes("")));
        assertFalse(success, "adapter unexpectedly exposes UUPS upgrade entrypoint");
    }
}
