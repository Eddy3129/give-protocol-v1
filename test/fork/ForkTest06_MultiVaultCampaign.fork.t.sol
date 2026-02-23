// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title   ForkTest06_MultiVaultCampaign
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
import {ForkHelperConfig} from "./ForkHelperConfig.sol";
import {ACLManager} from "../../src/governance/ACLManager.sol";
import {StrategyRegistry} from "../../src/registry/StrategyRegistry.sol";
import {CampaignRegistry} from "../../src/registry/CampaignRegistry.sol";
import {NGORegistry} from "../../src/donation/NGORegistry.sol";
import {GiveVault4626} from "../../src/vault/GiveVault4626.sol";
import {AaveAdapter} from "../../src/adapters/AaveAdapter.sol";
import {PayoutRouter} from "../../src/payout/PayoutRouter.sol";
import {IYieldAdapter} from "../../src/interfaces/IYieldAdapter.sol";
import {GiveTypes} from "../../src/types/GiveTypes.sol";

contract ForkTest06_MultiVaultCampaign is ForkBase {
    event VaultReassigned(address indexed vault, bytes32 indexed oldCampaignId, bytes32 indexed newCampaignId);

    bytes32 internal constant CAMPAIGN_A = keccak256("campaign_a");
    bytes32 internal constant CAMPAIGN_B = keccak256("campaign_b");
    bytes32 internal constant STRATEGY_USDC = keccak256("fork06.strategy.aave.usdc");
    bytes32 internal constant STRATEGY_WETH = keccak256("fork06.strategy.aave.weth");

    uint256 internal constant USDC_DEPOSIT = 20_000e6;
    uint256 internal constant WETH_DEPOSIT = 20 ether;
    CampaignRegistry internal registry;

    StrategyRegistry internal strategyRegistry;
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

        ForkHelperConfig.RegistrySuite memory suite = ForkHelperConfig.initAllRegistries(admin);
        ACLManager acl = suite.acl;
        strategyRegistry = suite.strategyRegistry;
        registry = suite.campaignRegistry;
        NGORegistry ngoRegistry = suite.ngoRegistry;

        vm.startPrank(admin);
        ForkHelperConfig.grantCoreProtocolRoles(acl, admin, address(0));
        ForkHelperConfig.grantNgoRegistryRoles(acl, admin, address(0));
        ForkHelperConfig.wireCampaignNgoRegistry(registry, ngoRegistry);
        ForkHelperConfig.addApprovedNgo(ngoRegistry, ngoA, "ipfs://fork06/ngo-a", keccak256("fork06-ngo-a"));
        ForkHelperConfig.addApprovedNgo(ngoRegistry, ngoB, "ipfs://fork06/ngo-b", keccak256("fork06-ngo-b"));
        vm.stopPrank();
        vm.deal(admin, 10 ether);

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
        strategyRegistry.registerStrategy(
            StrategyRegistry.StrategyInput({
                id: STRATEGY_USDC,
                adapter: address(usdcAdapter),
                riskTier: keccak256("LOW"),
                maxTvl: 10_000_000e6,
                metadataHash: keccak256("ipfs://fork06/aave-usdc")
            })
        );
        strategyRegistry.registerStrategy(
            StrategyRegistry.StrategyInput({
                id: STRATEGY_WETH,
                adapter: address(wethAdapter),
                riskTier: keccak256("LOW"),
                maxTvl: 5_000 ether,
                metadataHash: keccak256("ipfs://fork06/aave-weth")
            })
        );
        vm.stopPrank();

        _submitApproveAndActivateCampaign(CAMPAIGN_A, ngoA, STRATEGY_USDC, "ipfs://fork06/campaign-a");
        _submitApproveAndActivateCampaign(CAMPAIGN_B, ngoB, STRATEGY_WETH, "ipfs://fork06/campaign-b");

        vm.startPrank(admin);
        strategyRegistry.registerStrategyVault(STRATEGY_USDC, address(usdcVault));
        strategyRegistry.registerStrategyVault(STRATEGY_WETH, address(wethVault));

        usdcVault.setActiveAdapter(IYieldAdapter(address(usdcAdapter)));
        wethVault.setActiveAdapter(IYieldAdapter(address(wethAdapter)));
        usdcVault.setDonationRouter(address(router));
        wethVault.setDonationRouter(address(router));

        registry.setCampaignVault(CAMPAIGN_A, address(usdcVault), ForkHelperConfig.LOCK_PROFILE_STANDARD);
        registry.setCampaignVault(CAMPAIGN_A, address(wethVault), ForkHelperConfig.LOCK_PROFILE_STANDARD);

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

    function _submitApproveAndActivateCampaign(
        bytes32 campaignId,
        address payoutRecipient,
        bytes32 strategyId,
        string memory metadataCid
    ) internal {
        CampaignRegistry.CampaignInput memory input = CampaignRegistry.CampaignInput({
            id: campaignId,
            payoutRecipient: payoutRecipient,
            strategyId: strategyId,
            metadataHash: keccak256(bytes(metadataCid)),
            metadataCID: metadataCid,
            targetStake: ForkHelperConfig.DEFAULT_TARGET_STAKE_USDC,
            minStake: ForkHelperConfig.DEFAULT_MIN_STAKE_USDC,
            fundraisingStart: uint64(block.timestamp),
            fundraisingEnd: 0
        });

        vm.deal(payoutRecipient, 1 ether);
        vm.prank(payoutRecipient);
        registry.submitCampaign{value: ForkHelperConfig.CAMPAIGN_SUBMISSION_DEPOSIT}(input);
        vm.prank(admin);
        registry.approveCampaign(campaignId, admin);
        vm.prank(admin);
        registry.setCampaignStatus(campaignId, GiveTypes.CampaignStatus.Active);
    }
}
