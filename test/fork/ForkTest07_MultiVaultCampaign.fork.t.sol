// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title   ForkTest07_MultiVaultCampaign
 * @author  GIVE Labs
 * @notice  Fork test for Phase 5.5 GAP-4: single campaign, multiple vaults
 * @dev     Tests vault preference management when multiple vaults support one campaign:
 *          - Campaign vault reassignment based on performance or curator action
 *          - Preference stale-clearing across vault instances
 *          - Multi-vault yield aggregation and distribution
 */

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {ForkBase} from "./ForkBase.t.sol";
import {ForkAddresses} from "./ForkAddresses.sol";
import {GiveVault4626} from "../../src/vault/GiveVault4626.sol";
import {AaveAdapter} from "../../src/adapters/AaveAdapter.sol";
import {PayoutRouter} from "../../src/payout/PayoutRouter.sol";
import {IYieldAdapter} from "../../src/interfaces/IYieldAdapter.sol";
import {GiveTypes} from "../../src/types/GiveTypes.sol";

contract ForkMockACLForMultiVault {
    function hasRole(bytes32, address) external pure returns (bool) {
        return false;
    }
}

contract ForkMockCampaignRegistryMultiVault {
    mapping(bytes32 => GiveTypes.CampaignConfig) internal campaigns;

    function setCampaign(bytes32 campaignId, address payoutRecipient, bool payoutsHalted) external {
        GiveTypes.CampaignConfig storage cfg = campaigns[campaignId];
        cfg.id = campaignId;
        cfg.payoutRecipient = payoutRecipient;
        cfg.status = GiveTypes.CampaignStatus.Active;
        cfg.payoutsHalted = payoutsHalted;
        cfg.exists = true;
    }

    function getCampaign(bytes32 id) external view returns (GiveTypes.CampaignConfig memory cfg) {
        return campaigns[id];
    }
}

contract ForkTest07_MultiVaultCampaign is ForkBase {
    event VaultReassigned(address indexed vault, bytes32 indexed oldCampaignId, bytes32 indexed newCampaignId);

    bytes32 internal constant CAMPAIGN_A = keccak256("campaign_a");
    bytes32 internal constant CAMPAIGN_B = keccak256("campaign_b");

    uint256 internal constant USDC_DEPOSIT = 20_000e6;
    uint256 internal constant WETH_DEPOSIT = 20 ether;

    ForkMockCampaignRegistryMultiVault internal registry;
    PayoutRouter internal router;

    GiveVault4626 internal usdcVault;
    GiveVault4626 internal wethVault;

    AaveAdapter internal usdcAdapter;
    AaveAdapter internal wethAdapter;

    IERC20 internal usdc;
    IERC20 internal weth;

    address internal admin;
    address internal ngoA;
    address internal ngoB;
    address internal beneficiary;
    address internal user1;
    address internal user2;

    function setUp() public override {
        super.setUp();
        if (!_forkActive) return;

        usdc = IERC20(ForkAddresses.USDC);
        weth = IERC20(ForkAddresses.WETH);

        admin = makeAddr("multi_admin");
        ngoA = makeAddr("multi_ngo_a");
        ngoB = makeAddr("multi_ngo_b");
        beneficiary = makeAddr("multi_beneficiary");
        user1 = makeAddr("multi_user_1");
        user2 = makeAddr("multi_user_2");

        ForkMockACLForMultiVault acl = new ForkMockACLForMultiVault();
        registry = new ForkMockCampaignRegistryMultiVault();
        registry.setCampaign(CAMPAIGN_A, ngoA, false);
        registry.setCampaign(CAMPAIGN_B, ngoB, false);

        router = new PayoutRouter();
        vm.startPrank(admin);
        router.initialize(admin, address(acl), address(registry), admin, admin, 250);
        router.grantRole(router.VAULT_MANAGER_ROLE(), admin);
        vm.stopPrank();

        usdcVault = _deployVault(ForkAddresses.USDC, "Give USDC Vault", "gUSDC", address(acl));
        wethVault = _deployVault(ForkAddresses.WETH, "Give WETH Vault", "gWETH", address(acl));

        usdcAdapter = new AaveAdapter(ForkAddresses.USDC, address(usdcVault), ForkAddresses.AAVE_POOL, admin);
        wethAdapter = new AaveAdapter(ForkAddresses.WETH, address(wethVault), ForkAddresses.AAVE_POOL, admin);

        vm.startPrank(admin);
        usdcVault.setActiveAdapter(IYieldAdapter(address(usdcAdapter)));
        wethVault.setActiveAdapter(IYieldAdapter(address(wethAdapter)));
        usdcVault.setDonationRouter(address(router));
        wethVault.setDonationRouter(address(router));

        router.registerCampaignVault(address(usdcVault), CAMPAIGN_A);
        router.registerCampaignVault(address(wethVault), CAMPAIGN_A);
        router.setAuthorizedCaller(address(usdcVault), true);
        router.setAuthorizedCaller(address(wethVault), true);
        vm.stopPrank();
    }

    function test_two_vaults_same_campaign_ngo_receives_both() public requiresFork {
        _depositUsdc(user1, USDC_DEPOSIT);
        _depositWeth(user1, WETH_DEPOSIT);

        vm.warp(block.timestamp + 30 days);

        vm.prank(admin);
        (uint256 usdcProfit,) = usdcVault.harvest();
        vm.prank(admin);
        (uint256 wethProfit,) = wethVault.harvest();

        assertGt(usdcProfit, 0, "no USDC profit");
        assertGt(wethProfit, 0, "no WETH profit");

        uint256 ngoUsdcBefore = usdc.balanceOf(ngoA);
        uint256 ngoWethBefore = weth.balanceOf(ngoA);

        vm.prank(user1);
        router.claimYield(address(usdcVault), ForkAddresses.USDC);
        vm.prank(user1);
        router.claimYield(address(wethVault), ForkAddresses.WETH);

        assertGt(usdc.balanceOf(ngoA), ngoUsdcBefore, "ngo did not receive USDC");
        assertGt(weth.balanceOf(ngoA), ngoWethBefore, "ngo did not receive WETH");
    }

    function test_share_accounting_isolated_between_vaults() public requiresFork {
        _depositUsdc(user1, USDC_DEPOSIT);
        _depositWeth(user2, WETH_DEPOSIT);

        vm.warp(block.timestamp + 30 days);

        vm.prank(admin);
        (uint256 usdcProfit,) = usdcVault.harvest();
        assertGt(usdcProfit, 0, "no USDC profit");

        uint256 user1UsdcClaim = _claimAs(user1, address(usdcVault), ForkAddresses.USDC);
        uint256 user2WethClaim = _claimAs(user2, address(wethVault), ForkAddresses.WETH);
        uint256 user2UsdcClaim = _claimAs(user2, address(usdcVault), ForkAddresses.USDC);

        assertGt(user1UsdcClaim, 0, "user1 should receive USDC yield");
        assertEq(user2WethClaim, 0, "user2 should not receive WETH yield without weth harvest");
        assertEq(user2UsdcClaim, 0, "user2 should not receive USDC yield without USDC shares");
    }

    function test_vault_reassignment_emits_event_and_stale_pref_claim_still_succeeds() public requiresFork {
        _depositUsdc(user1, USDC_DEPOSIT);

        vm.prank(user1);
        router.setVaultPreference(address(usdcVault), beneficiary, 50);

        vm.warp(block.timestamp + 30 days);
        vm.prank(admin);
        (uint256 usdcProfit,) = usdcVault.harvest();
        assertGt(usdcProfit, 0, "no USDC profit");

        vm.expectEmit(true, true, true, true, address(router));
        emit VaultReassigned(address(usdcVault), CAMPAIGN_A, CAMPAIGN_B);
        vm.prank(admin);
        router.registerCampaignVault(address(usdcVault), CAMPAIGN_B);

        uint256 ngoBBefore = usdc.balanceOf(ngoB);
        vm.prank(user1);
        uint256 claimed = router.claimYield(address(usdcVault), ForkAddresses.USDC);
        assertGt(claimed, 0, "claim should succeed after reassignment");
        assertGt(usdc.balanceOf(ngoB), ngoBBefore, "new campaign NGO should receive funds");

        GiveTypes.CampaignPreference memory pref = router.getVaultPreference(user1, address(usdcVault));
        assertEq(pref.campaignId, bytes32(0), "stale preference should be cleared");
    }

    function _deployVault(address asset, string memory name, string memory symbol, address acl)
        internal
        returns (GiveVault4626 vault)
    {
        vault = new GiveVault4626();
        vm.prank(admin);
        vault.initialize(asset, name, symbol, admin, acl, address(vault));
    }

    function _depositUsdc(address user, uint256 amount) internal {
        deal(ForkAddresses.USDC, user, amount);
        vm.startPrank(user);
        usdc.approve(address(usdcVault), amount);
        usdcVault.deposit(amount, user);
        vm.stopPrank();
    }

    function _depositWeth(address user, uint256 amount) internal {
        deal(ForkAddresses.WETH, user, amount);
        vm.startPrank(user);
        weth.approve(address(wethVault), amount);
        wethVault.deposit(amount, user);
        vm.stopPrank();
    }

    function _claimAs(address user, address vault, address asset) internal returns (uint256 claimed) {
        vm.prank(user);
        claimed = router.claimYield(vault, asset);
    }
}
