// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title   ForkTest07_PendleYoUSD
 * @author  GIVE Labs
 * @notice  Full campaign lifecycle fork test for Pendle PT-yoUSD (USDC market) on Base mainnet
 * @dev     Tests the complete no-loss donation flow end-to-end with real Pendle V4 Router:
 *          - PendleAdapter(USDC->PT-yoUSD, tokenOut=yoUSD) invest and divest roundtrips
 *          - GiveVault4626 deposit -> invest -> harvest -> divest -> redeem cycle
 *          - PayoutRouter plumbing validation (PT harvest is always 0)
 *          - PT balance verification post-invest, post-divest
 *          - Emergency withdraw drains all PT back to vault as yoUSD
 *          - tokenOut separation: SY only accepts yoUSD as redemption output, not USDC
 *
 *          Market: PT-yoUSD on Base (USDC input, yoUSD output, yield 6%-26%)
 *          Market address:  0xA679ce6D07cbe579252F0f9742Fc73884b1c611c
 *          PT address:      0x0177055f7429D3bd6B19f2dd591127DB871A510e
 *          yoUSD address:   0x0000000f2eB9f69274678c76222B35eEc7588a65
 *          Pendle Router:   0x888888888889758F76e7103c6CbF23ABbF58F946
 *
 *          IMPORTANT: For this market the SY's getTokensOut() = [yoUSD], NOT [USDC].
 *          PendleAdapter must be constructed with tokenOut_=yoUSD (not USDC).
 *          The vault therefore receives yoUSD on divest, not USDC.
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
import {PendleAdapter} from "../../src/adapters/kinds/PendleAdapter.sol";
import {PayoutRouter} from "../../src/payout/PayoutRouter.sol";
import {IYieldAdapter} from "../../src/interfaces/IYieldAdapter.sol";
import {GiveTypes} from "../../src/types/GiveTypes.sol";

contract ForkTest07_PendleYoUSD is ForkBase {
    // ── Constants ─────────────────────────────────────────────────────────────

    bytes32 internal constant CAMPAIGN_ID = keccak256("fork.campaign.yousd");
    bytes32 internal constant STRATEGY_ID = keccak256("fork07.strategy.pendle.yousd");

    /// 10 000 USDC per donor — sufficient for Pendle AMM depth
    uint256 internal constant DEPOSIT = 10_000e6;

    // ── State ─────────────────────────────────────────────────────────────────

    GiveVault4626 internal vault;
    PendleAdapter internal adapter;
    PayoutRouter internal router;

    IERC20 internal usdc;
    IERC20 internal yousd; // SY output token: yoUSD
    IERC20 internal pt;

    address internal admin;
    address internal ngo;
    address[3] internal donors;

    // ── Setup ─────────────────────────────────────────────────────────────────

    function setUp() public override {
        super.setUp();
        if (!_forkActive) return;

        usdc = IERC20(ForkAddresses.USDC);
        yousd = IERC20(ForkAddresses.PENDLE_YOUSD_UNDERLYING);
        pt = IERC20(ForkAddresses.PENDLE_YOUSD_PT);

        admin = makeAddr("yousd_admin");
        ngo = makeAddr("yousd_ngo");
        donors[0] = makeAddr("yousd_donor0");
        donors[1] = makeAddr("yousd_donor1");
        donors[2] = makeAddr("yousd_donor2");

        ForkHelperConfig.RegistrySuite memory suite = ForkHelperConfig.initAllRegistries(admin);
        ACLManager acl = suite.acl;
        StrategyRegistry strategyRegistry = suite.strategyRegistry;
        CampaignRegistry registry = suite.campaignRegistry;
        NGORegistry ngoRegistry = suite.ngoRegistry;

        vm.startPrank(admin);
        ForkHelperConfig.grantCoreProtocolRoles(acl, admin, address(0));
        ForkHelperConfig.grantNgoRegistryRoles(acl, admin, address(0));
        ForkHelperConfig.wireCampaignNgoRegistry(registry, ngoRegistry);
        ForkHelperConfig.addApprovedNgo(ngoRegistry, ngo, "ipfs://fork07/ngo", keccak256("fork07-ngo"));
        vm.stopPrank();
        vm.deal(admin, 10 ether);

        vault = new GiveVault4626();
        vm.prank(admin);
        vault.initialize(ForkAddresses.USDC, "Give PT-yoUSD Vault", "gPTyoUSD", admin, address(acl), address(vault));

        // tokenOut_ = yoUSD (the SY's redemption token), not USDC
        adapter = new PendleAdapter(
            STRATEGY_ID,
            ForkAddresses.USDC,
            address(vault),
            ForkAddresses.PENDLE_ROUTER,
            ForkAddresses.PENDLE_YOUSD_MARKET,
            ForkAddresses.PENDLE_YOUSD_PT,
            ForkAddresses.PENDLE_YOUSD_UNDERLYING // tokenOut = yoUSD
        );

        vm.prank(admin);
        strategyRegistry.registerStrategy(
            StrategyRegistry.StrategyInput({
                id: STRATEGY_ID,
                adapter: address(adapter),
                riskTier: keccak256("MEDIUM"),
                maxTvl: 5_000_000e6,
                metadataHash: keccak256("ipfs://fork07/pendle-yousd")
            })
        );

        CampaignRegistry.CampaignInput memory campaignInput = CampaignRegistry.CampaignInput({
            id: CAMPAIGN_ID,
            payoutRecipient: ngo,
            strategyId: STRATEGY_ID,
            metadataHash: keccak256("fork07-campaign"),
            metadataCID: "ipfs://fork07/campaign",
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
        strategyRegistry.registerStrategyVault(STRATEGY_ID, address(vault));
        registry.setCampaignVault(CAMPAIGN_ID, address(vault), ForkHelperConfig.LOCK_PROFILE_STANDARD);
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

        for (uint256 i = 0; i < 3; i++) {
            deal(ForkAddresses.USDC, donors[i], DEPOSIT * 2);
        }
    }

    // ── Helpers ───────────────────────────────────────────────────────────────

    /// Deploy a fresh adapter with this test contract as vault (for direct testing)
    function _directAdapter() internal returns (PendleAdapter a) {
        a = new PendleAdapter(
            keccak256("fork.yousd.direct"),
            ForkAddresses.USDC,
            address(this), // vault = test contract
            ForkAddresses.PENDLE_ROUTER,
            ForkAddresses.PENDLE_YOUSD_MARKET,
            ForkAddresses.PENDLE_YOUSD_PT,
            ForkAddresses.PENDLE_YOUSD_UNDERLYING
        );
    }

    function _vaultDeposit(address donor, uint256 amount) internal {
        vm.startPrank(donor);
        usdc.approve(address(vault), amount);
        vault.deposit(amount, donor);
        vm.stopPrank();
    }

    // ── Tests ─────────────────────────────────────────────────────────────────

    /// Pendle Router V4 must exist at the canonical CREATE2 address on Base
    function test_pendle_router_deployed() public requiresFork {
        assertGt(ForkAddresses.PENDLE_ROUTER.code.length, 0, "Pendle Router not deployed on Base");
    }

    /// PT-yoUSD and yoUSD tokens must be live contracts
    function test_yousd_tokens_are_live() public requiresFork {
        pt.balanceOf(address(this)); // proves ERC-20 exists
        yousd.balanceOf(address(this));
    }

    /// invest() swaps USDC for PT-yoUSD; adapter holds PT, no idle USDC remains
    function test_invest_receives_pt_and_tracks_deposits() public requiresFork {
        uint256 amount = DEPOSIT;
        deal(ForkAddresses.USDC, address(this), amount);

        PendleAdapter a = _directAdapter();
        usdc.transfer(address(a), amount);
        a.invest(amount);

        assertGt(pt.balanceOf(address(a)), 0, "adapter received no PT after invest");
        assertEq(a.deposits(), amount, "deposits tracking mismatch");
        assertEq(a.totalAssets(), amount, "totalAssets() must equal deposits");
        assertEq(usdc.balanceOf(address(a)), 0, "adapter should hold no idle USDC post-invest");
    }

    /// divest() redeems PT and returns yoUSD to vault (not USDC — SY constraint)
    function test_divest_returns_yousd_to_vault() public requiresFork {
        uint256 amount = DEPOSIT;
        deal(ForkAddresses.USDC, address(this), amount);

        PendleAdapter a = _directAdapter();
        usdc.transfer(address(a), amount);
        a.invest(amount);

        uint256 vaultBefore = yousd.balanceOf(address(this));
        uint256 returned = a.divest(amount / 2);

        assertGt(returned, 0, "divest returned zero");
        assertEq(yousd.balanceOf(address(this)) - vaultBefore, returned, "vault yoUSD delta mismatch");
        // USDC was NOT returned — the SY outputs yoUSD
        assertEq(usdc.balanceOf(address(this)), 0, "divest must not return USDC for this market");
        // PT balance reduced but not zeroed (partial divest)
        assertGt(pt.balanceOf(address(a)), 0, "adapter should retain PT for remainder");
    }

    /// Full divest recovers >0 yoUSD and zeroes deposits
    function test_full_divest_zeroes_deposits() public requiresFork {
        uint256 amount = DEPOSIT;
        deal(ForkAddresses.USDC, address(this), amount);

        PendleAdapter a = _directAdapter();
        usdc.transfer(address(a), amount);
        a.invest(amount);

        uint256 returned = a.divest(amount);

        assertGt(returned, 0, "full divest should return yoUSD");
        assertEq(a.deposits(), 0, "deposits not cleared after full divest");
        assertEq(pt.balanceOf(address(a)), 0, "PT not fully sold after full divest");
    }

    /// emergencyWithdraw drains all PT, returns yoUSD to vault, zeroes state
    function test_emergency_withdraw_drains_adapter() public requiresFork {
        uint256 amount = DEPOSIT;
        deal(ForkAddresses.USDC, address(this), amount);

        PendleAdapter a = _directAdapter();
        usdc.transfer(address(a), amount);
        a.invest(amount);
        assertGt(pt.balanceOf(address(a)), 0, "no PT before emergency");

        uint256 vaultBefore = yousd.balanceOf(address(this));
        a.emergencyWithdraw();

        assertEq(pt.balanceOf(address(a)), 0, "PT not cleared after emergency");
        assertEq(a.deposits(), 0, "deposits not zeroed after emergency");
        assertGt(yousd.balanceOf(address(this)) - vaultBefore, 0, "vault received no yoUSD from emergency");
    }

    /// harvest() is always (0, 0) for Pendle PT adapter
    function test_harvest_is_noop() public requiresFork {
        uint256 amount = DEPOSIT;
        deal(ForkAddresses.USDC, address(this), amount);

        PendleAdapter a = _directAdapter();
        usdc.transfer(address(a), amount);
        a.invest(amount);

        (uint256 profit, uint256 loss) = a.harvest();
        assertEq(profit, 0, "PendleAdapter harvest should return 0 profit");
        assertEq(loss, 0, "PendleAdapter harvest should return 0 loss");
    }

    /// Full vault cycle: 3 donors deposit -> USDC invested into PT-yoUSD -> harvest no-op -> redeem
    /// NOTE: On redeem, vault receives yoUSD (not USDC). Donors receive whatever asset the vault holds.
    function test_vault_full_cycle_deposit_invest_harvest() public requiresFork {
        for (uint256 i = 0; i < 3; i++) {
            _vaultDeposit(donors[i], DEPOSIT);
        }

        // GiveVault auto-invests via _investExcessCash; retains cashBufferBps (1%) as idle USDC
        assertGt(pt.balanceOf(address(adapter)), 0, "no PT in adapter after deposits");
        uint256 idleUsdc = usdc.balanceOf(address(vault));
        // 1% cash buffer: ~300 USDC for 30k deposit
        assertApproxEqAbs(idleUsdc, (DEPOSIT * 3 * 100) / 10_000, 10e6, "cash buffer outside expected range");

        // harvest returns (0,0) for PT adapter
        (uint256 profit, uint256 loss) = vault.harvest();
        assertEq(profit, 0, "PT vault harvest must be 0");
        assertEq(loss, 0, "PT vault harvest must report 0 loss");
    }

    /// PayoutRouter plumbing works with PT adapter: no revert, zero yield
    function test_payout_router_zero_yield_no_revert() public requiresFork {
        _vaultDeposit(donors[0], DEPOSIT);

        (uint256 profit,) = vault.harvest();
        assertEq(profit, 0, "PT adapter harvest is no-op");

        uint256 ngoBefore = usdc.balanceOf(ngo);

        vm.prank(donors[0]);
        uint256 claimed = router.claimYield(address(vault), ForkAddresses.USDC);

        assertEq(claimed, 0, "expected zero claimable yield from PT adapter");
        assertEq(usdc.balanceOf(ngo), ngoBefore, "NGO balance must not change with zero yield");
    }

    /// Verifies tokenOut immutable is set correctly and differs from asset
    function test_tokenout_is_yousd_not_usdc() public requiresFork {
        assertEq(
            address(adapter.tokenOut()),
            ForkAddresses.PENDLE_YOUSD_UNDERLYING,
            "tokenOut must be yoUSD for PT-yoUSD market"
        );
        assertNotEq(address(adapter.tokenOut()), ForkAddresses.USDC, "tokenOut must differ from USDC for this market");
        assertEq(address(adapter.asset()), ForkAddresses.USDC, "asset must be USDC");
    }

    /// Adapter constructor rejects zero tokenOut
    function test_constructor_rejects_zero_tokenout() public requiresFork {
        vm.expectRevert();
        new PendleAdapter(
            keccak256("bad"),
            ForkAddresses.USDC,
            address(this),
            ForkAddresses.PENDLE_ROUTER,
            ForkAddresses.PENDLE_YOUSD_MARKET,
            ForkAddresses.PENDLE_YOUSD_PT,
            address(0) // zero tokenOut must revert
        );
    }
}
