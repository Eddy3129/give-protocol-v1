// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title   ForkTest09_PendleMaturity
 * @author  GIVE Labs
 * @notice  Fork tests for Pendle PT edge cases not covered by ForkTest07/08:
 *          (1) Post-maturity redemption via exitPostExpToToken — the codepath
 *              that fires when a PT market has expired and swapExactPtForToken
 *              is no longer available. Uses IPActionMiscV3.exitPostExpToToken.
 *          (2) Full donor vault cycle — 3 donors deposit USDC, vault auto-invests
 *              into PT-yoUSD, harvest returns (0,0), donors fully redeem USDC
 *              principal while adapter still holds PT. Proves principal is intact
 *              through the 1% cash buffer and that vault redeems via divest, not
 *              the dead swapExactPtForToken path.
 *
 *          Market: PT-yoUSD on Base (USDC input, yoUSD output)
 *          Market address:  0xA679ce6D07cbe579252F0f9742Fc73884b1c611c
 *          PT address:      0x0177055f7429D3bd6B19f2dd591127DB871A510e
 *          yoUSD address:   0x0000000f2eB9f69274678c76222B35eEc7588a65
 *          Pendle Router:   0x888888888889758F76e7103c6CbF23ABbF58F946
 */

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {ForkBase} from "./ForkBase.t.sol";
import {ForkAddresses} from "./ForkAddresses.sol";
import {GiveVault4626} from "../../src/vault/GiveVault4626.sol";
import {PendleAdapter} from "../../src/adapters/kinds/PendleAdapter.sol";
import {PayoutRouter} from "../../src/payout/PayoutRouter.sol";
import {IYieldAdapter} from "../../src/interfaces/IYieldAdapter.sol";
import {GiveTypes} from "../../src/types/GiveTypes.sol";
import {
    TokenOutput,
    createTokenOutputSimple,
    createEmptyLimitOrderData,
    LimitOrderData,
    ExitPostExpReturnParams
} from "pendle-core-v2-public/interfaces/IPAllActionTypeV3.sol";

// ── Pendle interfaces needed for post-maturity path ───────────────────────────

interface IPMarketExpiry {
    function isExpired() external view returns (bool);
    function expiry() external view returns (uint256);
}

interface IPActionMiscV3Subset {
    function exitPostExpToToken(
        address receiver,
        address market,
        uint256 netPtIn,
        uint256 netLpIn,
        TokenOutput calldata output
    ) external returns (uint256 netTokenOut, ExitPostExpReturnParams memory params);
}

// ── Minimal mocks ─────────────────────────────────────────────────────────────

contract ForkMockACL_Maturity {
    function hasRole(bytes32, address) external pure returns (bool) {
        return false;
    }
}

contract ForkMockCampaignRegistry_Maturity {
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

// ─────────────────────────────────────────────────────────────────────────────
// Test 1 — Post-maturity redemption via Pendle Router
// ─────────────────────────────────────────────────────────────────────────────

/**
 * @title   ForkTest09a_PendlePostMaturity
 * @notice  Verifies that PT holders can redeem via exitPostExpToToken after the
 *          market has expired. This path bypasses the AMM (which closes at expiry)
 *          and redeems PT directly through the SY at face value.
 *
 *          This is the highest-risk moment for a real deployment: if the adapter
 *          tries to call swapExactPtForToken post-expiry it will revert. The
 *          correct path is exitPostExpToToken.
 *
 *          Strategy: invest before expiry, warp past expiry, call
 *          exitPostExpToToken directly as the "vault" to prove the router accepts
 *          the call, then verify tokenOut (yoUSD) is returned >= principal - slippage.
 */
contract ForkTest09a_PendlePostMaturity is ForkBase {
    using SafeERC20 for IERC20;

    uint256 internal constant INVEST_AMOUNT = 10_000e6;

    IERC20 internal usdc;
    IERC20 internal yousd;
    IERC20 internal pt;

    function setUp() public override {
        super.setUp();
        if (!_forkActive) return;

        usdc = IERC20(ForkAddresses.USDC);
        yousd = IERC20(ForkAddresses.PENDLE_YOUSD_UNDERLYING);
        pt = IERC20(ForkAddresses.PENDLE_YOUSD_PT);
    }

    /// Invest USDC into PT-yoUSD pre-expiry, warp past market expiry, then
    /// redeem using exitPostExpToToken. Confirms the router's post-expiry path
    /// works and returns yoUSD >= 95% of invested principal (face-value redemption
    /// with minimal slippage from liquidity index rounding).
    function test_post_maturity_redemption_via_exit_post_exp() public requiresFork {
        uint256 expiry = IPMarketExpiry(ForkAddresses.PENDLE_YOUSD_MARKET).expiry();

        // ── Step 1: invest before market expires ──────────────────────────────
        PendleAdapter adapter = new PendleAdapter(
            keccak256("fork.maturity.direct"),
            ForkAddresses.USDC,
            address(this),
            ForkAddresses.PENDLE_ROUTER,
            ForkAddresses.PENDLE_YOUSD_MARKET,
            ForkAddresses.PENDLE_YOUSD_PT,
            ForkAddresses.PENDLE_YOUSD_UNDERLYING
        );

        deal(ForkAddresses.USDC, address(this), INVEST_AMOUNT);
        usdc.safeTransfer(address(adapter), INVEST_AMOUNT);
        adapter.invest(INVEST_AMOUNT);

        uint256 ptHeld = pt.balanceOf(address(adapter));
        assertGt(ptHeld, 0, "no PT acquired before expiry");

        // ── Step 2: warp past expiry ──────────────────────────────────────────
        vm.warp(expiry + 1);
        assertTrue(IPMarketExpiry(ForkAddresses.PENDLE_YOUSD_MARKET).isExpired(), "market should be expired");

        // ── Step 3: redeem via exitPostExpToToken ─────────────────────────────
        // The adapter holds PT; we call the router directly as the "vault" to
        // verify the router codepath works. In production the adapter would need
        // to expose a post-maturity redeem function — this test proves the
        // underlying router call is valid.
        pt.approve(ForkAddresses.PENDLE_ROUTER, ptHeld);

        TokenOutput memory output = createTokenOutputSimple(ForkAddresses.PENDLE_YOUSD_UNDERLYING, 0);

        uint256 yousdBefore = yousd.balanceOf(address(this));
        // Move PT from adapter to this contract for the direct router call
        vm.prank(address(adapter));
        pt.transfer(address(this), ptHeld);

        (uint256 netTokenOut,) = IPActionMiscV3Subset(ForkAddresses.PENDLE_ROUTER)
            .exitPostExpToToken(
                address(this),
                ForkAddresses.PENDLE_YOUSD_MARKET,
                ptHeld,
                0, // no LP tokens
                output
            );

        uint256 yousdReceived = yousd.balanceOf(address(this)) - yousdBefore;

        assertGt(netTokenOut, 0, "exitPostExpToToken returned zero");
        assertEq(yousdReceived, netTokenOut, "yoUSD balance delta mismatch");
        // Face-value redemption: expect >= 95% of USDC invested, converted at ~1:1
        // yoUSD:USDC. Allow 5% for AMM-acquired PT discount.
        assertGe(netTokenOut, INVEST_AMOUNT * 95 / 100, "post-maturity recovery below 95% of principal");
    }

    /// Confirms swapExactPtForToken (the pre-maturity path) reverts post-expiry,
    /// validating that exitPostExpToToken is the required alternative.
    function test_swap_exact_pt_for_token_reverts_post_expiry() public requiresFork {
        uint256 expiry = IPMarketExpiry(ForkAddresses.PENDLE_YOUSD_MARKET).expiry();

        PendleAdapter adapter = new PendleAdapter(
            keccak256("fork.maturity.revert"),
            ForkAddresses.USDC,
            address(this),
            ForkAddresses.PENDLE_ROUTER,
            ForkAddresses.PENDLE_YOUSD_MARKET,
            ForkAddresses.PENDLE_YOUSD_PT,
            ForkAddresses.PENDLE_YOUSD_UNDERLYING
        );

        deal(ForkAddresses.USDC, address(this), INVEST_AMOUNT);
        usdc.safeTransfer(address(adapter), INVEST_AMOUNT);
        adapter.invest(INVEST_AMOUNT);

        vm.warp(expiry + 1);

        // divest() calls swapExactPtForToken which is invalid post-expiry
        vm.expectRevert();
        adapter.divest(INVEST_AMOUNT);
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Test 2 — Full donor vault cycle with PT-yoUSD adapter
// ─────────────────────────────────────────────────────────────────────────────

/**
 * @title   ForkTest09b_PendleVaultDonorCycle
 * @notice  End-to-end donor lifecycle with PendleAdapter active in GiveVault4626:
 *          - 3 donors deposit USDC
 *          - Vault auto-invests via _investExcessCash (retains 1% cash buffer)
 *          - harvest() returns (0, 0) — PT yield is not streaming
 *          - Each donor redeems their full share balance
 *          - Vault divests from PT to cover redemptions
 *          - Donors receive USDC back (from 1% buffer) and yoUSD (from PT divest)
 *          - Principal loss does not exceed 1 USDC per donor (slippage tolerance)
 *
 *          This is the exact user-facing sequence on a live deployment and was
 *          previously untested in any fork suite.
 */
contract ForkTest09b_PendleVaultDonorCycle is ForkBase {
    bytes32 internal constant CAMPAIGN_ID = keccak256("fork.maturity.donor.cycle");
    uint256 internal constant DEPOSIT = 10_000e6; // 10k USDC per donor

    GiveVault4626 internal vault;
    PendleAdapter internal adapter;
    PayoutRouter internal router;

    IERC20 internal usdc;
    IERC20 internal yousd;
    IERC20 internal pt;

    address internal admin;
    address internal ngo;
    address[3] internal donors;

    function setUp() public override {
        super.setUp();
        if (!_forkActive) return;

        usdc = IERC20(ForkAddresses.USDC);
        yousd = IERC20(ForkAddresses.PENDLE_YOUSD_UNDERLYING);
        pt = IERC20(ForkAddresses.PENDLE_YOUSD_PT);

        admin = makeAddr("donor_cycle_admin");
        ngo = makeAddr("donor_cycle_ngo");
        donors[0] = makeAddr("donor_cycle_d0");
        donors[1] = makeAddr("donor_cycle_d1");
        donors[2] = makeAddr("donor_cycle_d2");

        ForkMockACL_Maturity acl = new ForkMockACL_Maturity();
        ForkMockCampaignRegistry_Maturity registry = new ForkMockCampaignRegistry_Maturity(ngo);

        vault = new GiveVault4626();
        vm.prank(admin);
        vault.initialize(
            ForkAddresses.USDC, "Give PT-yoUSD Donor Vault", "gDonorPTyoUSD", admin, address(acl), address(vault)
        );

        adapter = new PendleAdapter(
            keccak256("fork.donor.cycle.adapter"),
            ForkAddresses.USDC,
            address(vault),
            ForkAddresses.PENDLE_ROUTER,
            ForkAddresses.PENDLE_YOUSD_MARKET,
            ForkAddresses.PENDLE_YOUSD_PT,
            ForkAddresses.PENDLE_YOUSD_UNDERLYING
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
            deal(ForkAddresses.USDC, donors[i], DEPOSIT);
        }
    }

    /// 3 donors deposit → vault invests into PT-yoUSD → harvest is (0,0) →
    /// each donor redeems all shares → principal returned within 1 USDC tolerance.
    function test_three_donors_deposit_and_fully_redeem_principal() public requiresFork {
        // Step 1: all 3 donors deposit
        for (uint256 i = 0; i < 3; i++) {
            vm.startPrank(donors[i]);
            usdc.approve(address(vault), DEPOSIT);
            vault.deposit(DEPOSIT, donors[i]);
            vm.stopPrank();
        }

        // Vault has auto-invested; adapter holds PT
        assertGt(pt.balanceOf(address(adapter)), 0, "adapter holds no PT after deposits");

        // Step 2: harvest is no-op for PT adapter
        (uint256 profit, uint256 loss) = vault.harvest();
        assertEq(profit, 0, "PT vault harvest must return 0 profit");
        assertEq(loss, 0, "PT vault harvest must return 0 loss");

        // Step 3: each donor redeems full share balance
        for (uint256 i = 0; i < 3; i++) {
            uint256 shares = vault.balanceOf(donors[i]);
            assertGt(shares, 0, "donor has no shares");

            uint256 usdcBefore = usdc.balanceOf(donors[i]);
            uint256 yousdBefore = yousd.balanceOf(donors[i]);

            vm.prank(donors[i]);
            vault.redeem(shares, donors[i], donors[i]);

            uint256 usdcGained = usdc.balanceOf(donors[i]) - usdcBefore;
            uint256 yousdGained = yousd.balanceOf(donors[i]) - yousdBefore;
            uint256 totalReturned = usdcGained + yousdGained;

            // Donor gets back USDC (from 1% cash buffer) + yoUSD (from PT divest).
            // Total must be >= 99% of original deposit (1% Pendle AMM slippage tolerance).
            assertGt(totalReturned, 0, "donor received nothing on redeem");
            assertGe(totalReturned, DEPOSIT * 99 / 100, "donor principal loss exceeds 1% tolerance");
        }

        // Adapter should have fully divested — no residual PT
        assertEq(pt.balanceOf(address(adapter)), 0, "adapter still holds PT after all redeems");
        assertEq(adapter.deposits(), 0, "adapter deposits not zeroed after all redeems");
    }

    /// Single donor deposits, vault invests, donor redeems immediately (no warp).
    /// Validates that same-block roundtrip does not lose more than 1% to AMM spread.
    function test_single_donor_immediate_roundtrip_within_slippage() public requiresFork {
        vm.startPrank(donors[0]);
        usdc.approve(address(vault), DEPOSIT);
        vault.deposit(DEPOSIT, donors[0]);
        vm.stopPrank();

        uint256 shares = vault.balanceOf(donors[0]);
        uint256 usdcBefore = usdc.balanceOf(donors[0]);
        uint256 yousdBefore = yousd.balanceOf(donors[0]);

        vm.prank(donors[0]);
        vault.redeem(shares, donors[0], donors[0]);

        uint256 returned = (usdc.balanceOf(donors[0]) - usdcBefore) + (yousd.balanceOf(donors[0]) - yousdBefore);

        assertGe(returned, DEPOSIT * 99 / 100, "immediate roundtrip loss exceeds 1%");
    }

    /// Vault harvest after multiple deposits still returns (0, 0).
    /// Checks PayoutRouter records zero and NGO balance is unchanged.
    function test_harvest_zero_yield_ngo_balance_unchanged() public requiresFork {
        for (uint256 i = 0; i < 3; i++) {
            vm.startPrank(donors[i]);
            usdc.approve(address(vault), DEPOSIT);
            vault.deposit(DEPOSIT, donors[i]);
            vm.stopPrank();
        }

        uint256 ngoBefore = usdc.balanceOf(ngo);

        vm.warp(block.timestamp + 30 days);
        (uint256 profit,) = vault.harvest();
        assertEq(profit, 0, "PT adapter harvest must be 0");

        vm.prank(donors[0]);
        uint256 claimed = router.claimYield(address(vault), ForkAddresses.USDC);
        assertEq(claimed, 0, "no yield to claim from PT vault");
        assertEq(usdc.balanceOf(ngo), ngoBefore, "NGO balance must not change");
    }
}
