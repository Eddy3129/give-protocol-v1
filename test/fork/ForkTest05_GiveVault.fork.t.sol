// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title   ForkTest05_GiveVault
 * @author  GIVE Labs
 * @notice  End-to-end vault lifecycle test against live Aave V3 on Base mainnet
 * @dev     Tests full vault cycle with real Aave integration:
 *          - Deposit → Invest in Aave → Yield accrual
 *          - Harvest → Yield distribution via PayoutRouter
 *          - Redeem → Divest from Aave → Return to user
 *          - Emergency shutdown and grace period flows
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

contract ForkTest05_GiveVault is ForkBase {
    GiveVault4626 internal vault;
    AaveAdapter internal adapter;
    PayoutRouter internal router;

    IERC20 internal usdc;
    IERC20 internal ausdc;

    address internal admin;
    address internal ngo;
    address[3] internal donors;

    bytes32 internal constant CAMPAIGN_ID = keccak256("fork_campaign");
    bytes32 internal constant STRATEGY_ID = keccak256("fork.strategy.aave.usdc");
    uint256 internal constant DEPOSIT = 10_000e6; // 10k USDC per donor

    function setUp() public override {
        super.setUp();
        if (!_forkActive) return;

        usdc = IERC20(ForkAddresses.USDC);
        ausdc = IERC20(ForkAddresses.AUSDC);

        admin = makeAddr("fork_admin");
        ngo = makeAddr("fork_ngo");
        donors[0] = makeAddr("fork_donor0");
        donors[1] = makeAddr("fork_donor1");
        donors[2] = makeAddr("fork_donor2");

        // ── Deploy contracts (production-grade, no mocks) ────────────
        ForkHelperConfig.RegistrySuite memory suite = ForkHelperConfig.initAllRegistries(admin);
        ACLManager acl = suite.acl;
        StrategyRegistry strategyRegistry = suite.strategyRegistry;
        CampaignRegistry registry = suite.campaignRegistry;
        NGORegistry ngoRegistry = suite.ngoRegistry;

        vm.startPrank(admin);
        ForkHelperConfig.grantCoreProtocolRoles(acl, admin, address(0));
        ForkHelperConfig.grantNgoRegistryRoles(acl, admin, address(0));
        ForkHelperConfig.wireCampaignNgoRegistry(registry, ngoRegistry);
        ForkHelperConfig.addApprovedNgo(ngoRegistry, ngo, "ipfs://fork05/ngo", keccak256("fork05-ngo"));
        vm.stopPrank();

        vm.deal(admin, 10 ether);

        vault = new GiveVault4626();
        vm.prank(admin);
        vault.initialize(ForkAddresses.USDC, "Give USDC Vault", "gUSDC", admin, address(acl), address(vault));

        adapter = new AaveAdapter(ForkAddresses.USDC, address(vault), ForkAddresses.AAVE_POOL, admin);

        vm.prank(admin);
        strategyRegistry.registerStrategy(
            StrategyRegistry.StrategyInput({
                id: STRATEGY_ID,
                adapter: address(adapter),
                riskTier: keccak256("LOW"),
                maxTvl: 10_000_000e6,
                metadataHash: keccak256("ipfs://fork05/aave-usdc")
            })
        );

        CampaignRegistry.CampaignInput memory campaignInput = CampaignRegistry.CampaignInput({
            id: CAMPAIGN_ID,
            payoutRecipient: ngo,
            strategyId: STRATEGY_ID,
            metadataHash: keccak256("fork05-campaign"),
            metadataCID: "ipfs://fork05/campaign",
            targetStake: ForkHelperConfig.DEFAULT_TARGET_STAKE_USDC,
            minStake: ForkHelperConfig.DEFAULT_MIN_STAKE_USDC,
            fundraisingStart: uint64(block.timestamp),
            fundraisingEnd: 0
        });

        vm.deal(ngo, 1 ether);
        vm.prank(ngo);
        registry.submitCampaign{value: ForkHelperConfig.CAMPAIGN_SUBMISSION_DEPOSIT}(campaignInput);
        vm.startPrank(admin);
        registry.approveCampaign(CAMPAIGN_ID, admin);
        registry.setCampaignStatus(CAMPAIGN_ID, GiveTypes.CampaignStatus.Active);
        registry.setCampaignVault(CAMPAIGN_ID, address(vault), ForkHelperConfig.LOCK_PROFILE_STANDARD);
        strategyRegistry.registerStrategyVault(STRATEGY_ID, address(vault));
        vm.stopPrank();

        router = new PayoutRouter();
        vm.startPrank(admin);
        router.initialize(admin, address(acl), address(registry), admin, admin, 250);
        router.grantRole(router.VAULT_MANAGER_ROLE(), admin);
        router.registerCampaignVault(address(vault), CAMPAIGN_ID);
        router.setAuthorizedCaller(address(vault), true);

        vault.setActiveAdapter(IYieldAdapter(address(adapter)));
        vault.setDonationRouter(address(router));
        vm.stopPrank();

        // ── Fund donors ───────────────────────────────────────────────
        for (uint256 i = 0; i < 3; i++) {
            _dealUsdc(donors[i], DEPOSIT * 2); // extra buffer for potential slippage
        }
    }

    // ── Tests ─────────────────────────────────────────────────────────

    function test_full_cycle_deposit_invest_yield_harvest_claim_withdraw() public requiresFork {
        // Step 1: donors deposit
        for (uint256 i = 0; i < 3; i++) {
            vm.startPrank(donors[i]);
            usdc.approve(address(vault), DEPOSIT);
            vault.deposit(DEPOSIT, donors[i]);
            vm.stopPrank();
        }
        assertGt(ausdc.balanceOf(address(adapter)), 0, "nothing invested after deposit");

        // Step 2: 30-day yield accrual
        vm.warp(block.timestamp + 30 days);

        // Step 3: harvest — profit flows to PayoutRouter via recordYield
        uint256 ngoBalanceBefore = usdc.balanceOf(ngo);
        vm.prank(admin);
        (uint256 profit,) = vault.harvest();
        assertGt(profit, 0, "no yield after 30 days");

        // Step 4: donors claim yield (routes to NGO + optional beneficiary)
        for (uint256 i = 0; i < 3; i++) {
            vm.prank(donors[i]);
            router.claimYield(address(vault), ForkAddresses.USDC);
        }
        assertGt(usdc.balanceOf(ngo), ngoBalanceBefore, "NGO received no USDC");

        // Step 5: donors redeem principal
        for (uint256 i = 0; i < 3; i++) {
            uint256 shares = vault.balanceOf(donors[i]);
            vm.prank(donors[i]);
            uint256 returned = vault.redeem(shares, donors[i], donors[i]);
            // Principal must be fully returned (no loss without bad adapter)
            assertGe(returned, DEPOSIT - 5, "donor lost principal beyond dust tolerance");
        }
    }

    function test_share_price_nondecreasing_after_90_days() public requiresFork {
        vm.startPrank(donors[0]);
        usdc.approve(address(vault), DEPOSIT);
        vault.deposit(DEPOSIT, donors[0]);
        vm.stopPrank();

        uint256 priceBefore = vault.previewRedeem(vault.balanceOf(donors[0]));

        vm.warp(block.timestamp + 90 days);
        vm.prank(admin);
        vault.harvest();

        uint256 priceAfter = vault.previewRedeem(vault.balanceOf(donors[0]));
        assertGe(priceAfter, priceBefore, "share price decreased");
    }

    function test_emergency_pause_pulls_funds_from_aave() public requiresFork {
        vm.startPrank(donors[0]);
        usdc.approve(address(vault), DEPOSIT);
        vault.deposit(DEPOSIT, donors[0]);
        vm.stopPrank();

        uint256 investedBefore = ausdc.balanceOf(address(adapter));
        assertGt(investedBefore, 0, "nothing in Aave before emergency");

        vm.prank(admin);
        vault.emergencyPause();

        assertTrue(vault.emergencyShutdown(), "vault not in emergency");
        assertLe(ausdc.balanceOf(address(adapter)), 1, "aUSDC not withdrawn on emergency");
        // Vault cash should contain at least 99% of what was invested
        assertGe(usdc.balanceOf(address(vault)), investedBefore * 99 / 100);
    }

    function test_total_assets_matches_onchain_balances() public requiresFork {
        vm.startPrank(donors[0]);
        usdc.approve(address(vault), DEPOSIT);
        vault.deposit(DEPOSIT, donors[0]);
        vm.stopPrank();

        uint256 vaultCash = usdc.balanceOf(address(vault));
        uint256 adapterAssets = adapter.totalAssets();

        assertEq(vault.totalAssets(), vaultCash + adapterAssets, "totalAssets() != cash + adapter");
    }
}
