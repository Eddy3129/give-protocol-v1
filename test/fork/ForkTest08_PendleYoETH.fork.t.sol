// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title   ForkTest08_PendleYoETH
 * @author  GIVE Labs
 * @notice  Full campaign lifecycle fork test for Pendle PT-yoETH (WETH market) on Base mainnet
 * @dev     Tests the complete no-loss donation flow end-to-end with real Pendle V4 Router:
 *          - PendleAdapter(WETH->PT-yoETH, tokenOut=yoETH) invest and divest roundtrips
 *          - GiveVault4626 deposit -> invest -> harvest -> divest cycle
 *          - Emergency withdraw drains all PT, vault receives yoETH
 *          - tokenOut separation: SY only accepts yoETH as redemption output, not WETH
 *          - Cross-market isolation: yoUSD and yoETH vaults share a campaign without interference
 *
 *          Market: PT-yoETH on Base (WETH input, yoETH output, yield 3%-13%)
 *          Market address:  0x5d6E67FcE4aD099363D062815B784d281460C49b
 *          PT address:      0x1A5c5eA50717a2ea0e4F7036FB289349DEaAB58b
 *          yoETH address:   0x3A43AEC53490CB9Fa922847385D82fe25d0E9De7
 *          Pendle Router:   0x888888888889758F76e7103c6CbF23ABbF58F946
 */

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {ForkBase} from "./ForkBase.t.sol";
import {ForkAddresses} from "./ForkAddresses.sol";
import {GiveVault4626} from "../../src/vault/GiveVault4626.sol";
import {PendleAdapter} from "../../src/adapters/kinds/PendleAdapter.sol";
import {PayoutRouter} from "../../src/payout/PayoutRouter.sol";
import {IYieldAdapter} from "../../src/interfaces/IYieldAdapter.sol";
import {GiveTypes} from "../../src/types/GiveTypes.sol";

// ── Minimal mocks ─────────────────────────────────────────────────────────────

contract ForkMockACL_YoETH {
    function hasRole(bytes32, address) external pure returns (bool) {
        return false;
    }
}

contract ForkMockCampaignRegistry_YoETH {
    address public immutable payoutRecipient;

    constructor(address r) {
        payoutRecipient = r;
    }

    function getCampaign(bytes32 id) external view returns (GiveTypes.CampaignConfig memory cfg) {
        uint256[49] memory gap;
        cfg.id = id;
        cfg.payoutRecipient = payoutRecipient;
        cfg.status = GiveTypes.CampaignStatus.Active;
        cfg.exists = true;
        cfg.__gap = gap;
    }
}

contract ForkTest08_PendleYoETH is ForkBase {
    // ── Constants ─────────────────────────────────────────────────────────────

    bytes32 internal constant CAMPAIGN_ID = keccak256("fork.campaign.yoeth");

    /// 5 WETH per donor (~$15k at $3k WETH — meaningful depth for yoETH market)
    uint256 internal constant DEPOSIT = 5 ether;

    // ── State ─────────────────────────────────────────────────────────────────

    GiveVault4626 internal vault;
    PendleAdapter internal adapter;
    PayoutRouter internal router;

    IERC20 internal weth;
    IERC20 internal yoeth; // SY output token
    IERC20 internal pt;

    address internal admin;
    address internal ngo;
    address[3] internal donors;

    // ── Setup ─────────────────────────────────────────────────────────────────

    function setUp() public override {
        super.setUp();
        if (!_forkActive) return;

        weth = IERC20(ForkAddresses.WETH);
        yoeth = IERC20(ForkAddresses.PENDLE_YOETH_UNDERLYING);
        pt = IERC20(ForkAddresses.PENDLE_YOETH_PT);

        admin = makeAddr("yoeth_admin");
        ngo = makeAddr("yoeth_ngo");
        donors[0] = makeAddr("yoeth_donor0");
        donors[1] = makeAddr("yoeth_donor1");
        donors[2] = makeAddr("yoeth_donor2");

        ForkMockACL_YoETH acl = new ForkMockACL_YoETH();
        ForkMockCampaignRegistry_YoETH registry = new ForkMockCampaignRegistry_YoETH(ngo);

        vault = new GiveVault4626();
        vm.prank(admin);
        vault.initialize(ForkAddresses.WETH, "Give PT-yoETH Vault", "gPTyoETH", admin, address(acl), address(vault));

        // tokenOut_ = yoETH (the SY's redemption token), not WETH
        adapter = new PendleAdapter(
            keccak256("fork.yoeth.adapter"),
            ForkAddresses.WETH,
            address(vault),
            ForkAddresses.PENDLE_ROUTER,
            ForkAddresses.PENDLE_YOETH_MARKET,
            ForkAddresses.PENDLE_YOETH_PT,
            ForkAddresses.PENDLE_YOETH_UNDERLYING // tokenOut = yoETH
        );

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
            deal(ForkAddresses.WETH, donors[i], DEPOSIT * 2);
        }
    }

    // ── Helpers ───────────────────────────────────────────────────────────────

    function _directAdapter() internal returns (PendleAdapter a) {
        a = new PendleAdapter(
            keccak256("fork.yoeth.direct"),
            ForkAddresses.WETH,
            address(this),
            ForkAddresses.PENDLE_ROUTER,
            ForkAddresses.PENDLE_YOETH_MARKET,
            ForkAddresses.PENDLE_YOETH_PT,
            ForkAddresses.PENDLE_YOETH_UNDERLYING
        );
    }

    function _vaultDeposit(address donor, uint256 amount) internal {
        vm.startPrank(donor);
        weth.approve(address(vault), amount);
        vault.deposit(amount, donor);
        vm.stopPrank();
    }

    // ── Tests ─────────────────────────────────────────────────────────────────

    /// Pendle Router V4 must exist on Base
    function test_pendle_router_deployed() public requiresFork {
        assertGt(ForkAddresses.PENDLE_ROUTER.code.length, 0, "Pendle Router not deployed on Base");
    }

    /// PT-yoETH and yoETH tokens must be live contracts
    function test_yoeth_tokens_are_live() public requiresFork {
        pt.balanceOf(address(this));
        yoeth.balanceOf(address(this));
    }

    /// invest() swaps WETH for PT-yoETH; adapter holds PT, no idle WETH remains
    function test_invest_receives_pt_and_tracks_deposits() public requiresFork {
        deal(ForkAddresses.WETH, address(this), DEPOSIT);

        PendleAdapter a = _directAdapter();
        weth.transfer(address(a), DEPOSIT);
        a.invest(DEPOSIT);

        assertGt(pt.balanceOf(address(a)), 0, "adapter received no PT after invest");
        assertEq(a.deposits(), DEPOSIT, "deposits tracking mismatch");
        assertEq(a.totalAssets(), DEPOSIT, "totalAssets() must equal deposits");
        assertEq(weth.balanceOf(address(a)), 0, "adapter should hold no idle WETH post-invest");
    }

    /// divest() redeems PT and returns yoETH to vault (not WETH — SY constraint)
    function test_divest_returns_yoeth_to_vault() public requiresFork {
        deal(ForkAddresses.WETH, address(this), DEPOSIT);

        PendleAdapter a = _directAdapter();
        weth.transfer(address(a), DEPOSIT);
        a.invest(DEPOSIT);

        uint256 vaultBefore = yoeth.balanceOf(address(this));
        uint256 returned = a.divest(DEPOSIT / 2);

        assertGt(returned, 0, "divest returned zero");
        assertEq(yoeth.balanceOf(address(this)) - vaultBefore, returned, "vault yoETH delta mismatch");
        assertEq(weth.balanceOf(address(this)), 0, "divest must not return WETH for this market");
        assertGt(pt.balanceOf(address(a)), 0, "adapter should retain PT for remainder");
    }

    /// Full divest recovers >0 yoETH and zeroes deposits
    function test_full_divest_zeroes_deposits() public requiresFork {
        deal(ForkAddresses.WETH, address(this), DEPOSIT);

        PendleAdapter a = _directAdapter();
        weth.transfer(address(a), DEPOSIT);
        a.invest(DEPOSIT);

        uint256 returned = a.divest(DEPOSIT);

        assertGt(returned, 0, "full divest should return yoETH");
        assertEq(a.deposits(), 0, "deposits not cleared after full divest");
        assertEq(pt.balanceOf(address(a)), 0, "PT not fully sold after full divest");
    }

    /// emergencyWithdraw drains all PT, returns yoETH to vault, zeroes state
    function test_emergency_withdraw_drains_adapter() public requiresFork {
        deal(ForkAddresses.WETH, address(this), DEPOSIT);

        PendleAdapter a = _directAdapter();
        weth.transfer(address(a), DEPOSIT);
        a.invest(DEPOSIT);
        assertGt(pt.balanceOf(address(a)), 0, "no PT before emergency");

        uint256 vaultBefore = yoeth.balanceOf(address(this));
        a.emergencyWithdraw();

        assertEq(pt.balanceOf(address(a)), 0, "PT not cleared after emergency");
        assertEq(a.deposits(), 0, "deposits not zeroed after emergency");
        assertGt(yoeth.balanceOf(address(this)) - vaultBefore, 0, "vault received no yoETH from emergency");
    }

    /// harvest() is always (0, 0)
    function test_harvest_is_noop() public requiresFork {
        deal(ForkAddresses.WETH, address(this), DEPOSIT);

        PendleAdapter a = _directAdapter();
        weth.transfer(address(a), DEPOSIT);
        a.invest(DEPOSIT);

        (uint256 profit, uint256 loss) = a.harvest();
        assertEq(profit, 0, "PendleAdapter harvest should return 0 profit");
        assertEq(loss, 0, "PendleAdapter harvest should return 0 loss");
    }

    /// Full vault cycle: donors deposit WETH -> invested into PT-yoETH -> harvest no-op
    function test_vault_full_cycle_deposit_invest_harvest() public requiresFork {
        for (uint256 i = 0; i < 3; i++) {
            _vaultDeposit(donors[i], DEPOSIT);
        }

        assertGt(pt.balanceOf(address(adapter)), 0, "no PT in adapter after deposits");
        // 1% cash buffer: ~0.15 WETH for 15 WETH total deposit
        uint256 idleWeth = weth.balanceOf(address(vault));
        assertApproxEqAbs(idleWeth, (DEPOSIT * 3 * 100) / 10_000, 0.1 ether, "cash buffer outside expected range");

        (uint256 profit, uint256 loss) = vault.harvest();
        assertEq(profit, 0, "PT vault harvest must be 0");
        assertEq(loss, 0, "PT vault harvest must report 0 loss");
    }

    /// PayoutRouter plumbing: zero yield, no revert
    function test_payout_router_zero_yield_no_revert() public requiresFork {
        _vaultDeposit(donors[0], DEPOSIT);

        (uint256 profit,) = vault.harvest();
        assertEq(profit, 0, "PT adapter harvest is no-op");

        uint256 ngoBefore = weth.balanceOf(ngo);

        vm.prank(donors[0]);
        uint256 claimed = router.claimYield(address(vault), ForkAddresses.WETH);

        assertEq(claimed, 0, "expected zero claimable yield from PT adapter");
        assertEq(weth.balanceOf(ngo), ngoBefore, "NGO balance must not change with zero yield");
    }

    /// Verifies tokenOut is yoETH, not WETH
    function test_tokenout_is_yoeth_not_weth() public requiresFork {
        assertEq(
            address(adapter.tokenOut()),
            ForkAddresses.PENDLE_YOETH_UNDERLYING,
            "tokenOut must be yoETH for PT-yoETH market"
        );
        assertNotEq(address(adapter.tokenOut()), ForkAddresses.WETH, "tokenOut must differ from WETH for this market");
        assertEq(address(adapter.asset()), ForkAddresses.WETH, "asset must be WETH");
    }
}

// ── Cross-market: yoUSD + yoETH vaults under one campaign ────────────────────

contract ForkMockACL_CrossPendle {
    function hasRole(bytes32, address) external pure returns (bool) {
        return false;
    }
}

contract ForkMockCampaignRegistry_CrossPendle {
    address public immutable payoutRecipient;

    constructor(address r) {
        payoutRecipient = r;
    }

    function getCampaign(bytes32 id) external view returns (GiveTypes.CampaignConfig memory cfg) {
        uint256[49] memory gap;
        cfg.id = id;
        cfg.payoutRecipient = payoutRecipient;
        cfg.status = GiveTypes.CampaignStatus.Active;
        cfg.exists = true;
        cfg.__gap = gap;
    }
}

/**
 * @title ForkTest12b_PendleCrossMarket
 * @notice yoUSD (USDC) and yoETH (WETH) Pendle vaults running concurrently under one campaign.
 *         Validates that vault accounting is fully isolated and no storage collisions occur.
 */
contract ForkTest08b_PendleCrossMarket is ForkBase {
    bytes32 internal constant CAMPAIGN_ID = keccak256("fork.campaign.cross.pendle");

    uint256 internal constant USDC_DEPOSIT = 10_000e6;
    uint256 internal constant WETH_DEPOSIT = 5 ether;

    GiveVault4626 internal usdcVault;
    GiveVault4626 internal wethVault;
    PendleAdapter internal usdcAdapter;
    PendleAdapter internal wethAdapter;
    PayoutRouter internal router;

    IERC20 internal usdc;
    IERC20 internal weth;
    IERC20 internal ptYoUSD;
    IERC20 internal ptYoETH;

    address internal admin;
    address internal ngo;
    address internal usdcDonor;
    address internal wethDonor;

    function setUp() public override {
        super.setUp();
        if (!_forkActive) return;

        usdc = IERC20(ForkAddresses.USDC);
        weth = IERC20(ForkAddresses.WETH);
        ptYoUSD = IERC20(ForkAddresses.PENDLE_YOUSD_PT);
        ptYoETH = IERC20(ForkAddresses.PENDLE_YOETH_PT);

        admin = makeAddr("cross_admin");
        ngo = makeAddr("cross_ngo");
        usdcDonor = makeAddr("cross_usdc_donor");
        wethDonor = makeAddr("cross_weth_donor");

        ForkMockACL_CrossPendle acl = new ForkMockACL_CrossPendle();
        ForkMockCampaignRegistry_CrossPendle registry = new ForkMockCampaignRegistry_CrossPendle(ngo);

        usdcVault = _newVault(ForkAddresses.USDC, "Give PT-yoUSD Vault", "gPTyoUSD", address(acl));
        wethVault = _newVault(ForkAddresses.WETH, "Give PT-yoETH Vault", "gPTyoETH", address(acl));

        usdcAdapter = new PendleAdapter(
            keccak256("cross.yousd"),
            ForkAddresses.USDC,
            address(usdcVault),
            ForkAddresses.PENDLE_ROUTER,
            ForkAddresses.PENDLE_YOUSD_MARKET,
            ForkAddresses.PENDLE_YOUSD_PT,
            ForkAddresses.PENDLE_YOUSD_UNDERLYING
        );

        wethAdapter = new PendleAdapter(
            keccak256("cross.yoeth"),
            ForkAddresses.WETH,
            address(wethVault),
            ForkAddresses.PENDLE_ROUTER,
            ForkAddresses.PENDLE_YOETH_MARKET,
            ForkAddresses.PENDLE_YOETH_PT,
            ForkAddresses.PENDLE_YOETH_UNDERLYING
        );

        router = new PayoutRouter();
        vm.startPrank(admin);
        router.initialize(admin, address(acl), address(registry), admin, admin, 250);
        router.grantRole(router.VAULT_MANAGER_ROLE(), admin);
        router.registerCampaignVault(address(usdcVault), CAMPAIGN_ID);
        router.registerCampaignVault(address(wethVault), CAMPAIGN_ID);
        router.setAuthorizedCaller(address(usdcVault), true);
        router.setAuthorizedCaller(address(wethVault), true);
        usdcVault.setActiveAdapter(IYieldAdapter(address(usdcAdapter)));
        wethVault.setActiveAdapter(IYieldAdapter(address(wethAdapter)));
        usdcVault.setDonationRouter(address(router));
        wethVault.setDonationRouter(address(router));
        vm.stopPrank();

        deal(ForkAddresses.USDC, usdcDonor, USDC_DEPOSIT * 2);
        deal(ForkAddresses.WETH, wethDonor, WETH_DEPOSIT * 2);
    }

    function _newVault(address asset, string memory name, string memory symbol, address acl)
        internal
        returns (GiveVault4626 v)
    {
        v = new GiveVault4626();
        vm.prank(admin);
        v.initialize(asset, name, symbol, admin, acl, address(v));
    }

    /// Both adapters hold their own PT; no cross-contamination between markets
    function test_cross_market_pt_balances_isolated() public requiresFork {
        vm.startPrank(usdcDonor);
        usdc.approve(address(usdcVault), USDC_DEPOSIT);
        usdcVault.deposit(USDC_DEPOSIT, usdcDonor);
        vm.stopPrank();

        vm.startPrank(wethDonor);
        weth.approve(address(wethVault), WETH_DEPOSIT);
        wethVault.deposit(WETH_DEPOSIT, wethDonor);
        vm.stopPrank();

        assertGt(ptYoUSD.balanceOf(address(usdcAdapter)), 0, "yoUSD adapter should hold PT-yoUSD");
        assertGt(ptYoETH.balanceOf(address(wethAdapter)), 0, "yoETH adapter should hold PT-yoETH");
        assertEq(ptYoUSD.balanceOf(address(wethAdapter)), 0, "yoETH adapter must not hold PT-yoUSD");
        assertEq(ptYoETH.balanceOf(address(usdcAdapter)), 0, "yoUSD adapter must not hold PT-yoETH");
    }

    /// Campaign routing is correct per vault
    function test_cross_market_campaign_routing_correct() public requiresFork {
        assertEq(router.getVaultCampaign(address(usdcVault)), CAMPAIGN_ID, "USDC vault campaign mismatch");
        assertEq(router.getVaultCampaign(address(wethVault)), CAMPAIGN_ID, "WETH vault campaign mismatch");
    }

    /// Both adapters return zero harvest (PT model — yield embedded in price)
    function test_cross_market_harvest_both_zero() public requiresFork {
        vm.startPrank(usdcDonor);
        usdc.approve(address(usdcVault), USDC_DEPOSIT);
        usdcVault.deposit(USDC_DEPOSIT, usdcDonor);
        vm.stopPrank();

        vm.startPrank(wethDonor);
        weth.approve(address(wethVault), WETH_DEPOSIT);
        wethVault.deposit(WETH_DEPOSIT, wethDonor);
        vm.stopPrank();

        (uint256 usdcProfit, uint256 usdcLoss) = usdcVault.harvest();
        (uint256 wethProfit, uint256 wethLoss) = wethVault.harvest();

        assertEq(usdcProfit, 0, "yoUSD vault harvest should be 0");
        assertEq(usdcLoss, 0, "yoUSD vault harvest loss should be 0");
        assertEq(wethProfit, 0, "yoETH vault harvest should be 0");
        assertEq(wethLoss, 0, "yoETH vault harvest loss should be 0");
    }

    /// Emergency pause drains both markets; each vault receives its SY output token
    function test_cross_market_emergency_drains_both() public requiresFork {
        vm.startPrank(usdcDonor);
        usdc.approve(address(usdcVault), USDC_DEPOSIT);
        usdcVault.deposit(USDC_DEPOSIT, usdcDonor);
        vm.stopPrank();

        vm.startPrank(wethDonor);
        weth.approve(address(wethVault), WETH_DEPOSIT);
        wethVault.deposit(WETH_DEPOSIT, wethDonor);
        vm.stopPrank();

        vm.prank(admin);
        usdcVault.emergencyPause();
        vm.prank(admin);
        wethVault.emergencyPause();

        // After emergency: adapters hold no PT
        assertEq(ptYoUSD.balanceOf(address(usdcAdapter)), 0, "yoUSD adapter still holds PT after emergency");
        assertEq(ptYoETH.balanceOf(address(wethAdapter)), 0, "yoETH adapter still holds PT after emergency");

        // Vaults receive yoUSD/yoETH (not USDC/WETH) — the SY output tokens
        IERC20 yousd = IERC20(ForkAddresses.PENDLE_YOUSD_UNDERLYING);
        IERC20 yoeth = IERC20(ForkAddresses.PENDLE_YOETH_UNDERLYING);
        assertGt(yousd.balanceOf(address(usdcVault)), 0, "USDC vault should have yoUSD after emergency");
        assertGt(yoeth.balanceOf(address(wethVault)), 0, "WETH vault should have yoETH after emergency");
    }
}
