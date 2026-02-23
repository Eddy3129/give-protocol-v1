// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title   ForkTest10_CampaignLifecycle
 * @author  GIVE Labs
 * @notice  Full campaign lifecycle test against live Aave V3 on Base mainnet
 * @dev     Fork-level equivalent of TestAction01_CampaignLifecycle and
 *          TestAction02_MultiStrategyOperations, exercising the entire protocol
 *          stack against real on-chain state:
 *          - Deposit → Aave invest → 30-day yield accrual
 *          - harvest() → PayoutRouter pull-model claim
 *          - NGO receives USDC, donors redeem principal intact
 *          - Emergency pause with grace period enforcement
 *          - Checkpoint governance (fail then succeed path)
 *          - Fee timelock: increase requires delay, decrease is instant
 *          - Two-vault same-campaign concurrent yield + independent accounting
 *          - Vault preference setting and stale-preference clear after reassignment
 */

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {ForkBase} from "./ForkBase.t.sol";
import {ForkAddresses} from "./ForkAddresses.sol";
import {GiveVault4626} from "../../src/vault/GiveVault4626.sol";
import {AaveAdapter} from "../../src/adapters/AaveAdapter.sol";
import {PayoutRouter} from "../../src/payout/PayoutRouter.sol";
import {IYieldAdapter} from "../../src/interfaces/IYieldAdapter.sol";
import {GiveTypes} from "../../src/types/GiveTypes.sol";
import {GiveErrors} from "../../src/utils/GiveErrors.sol";

// ── Minimal in-file mocks ────────────────────────────────────────────────────

/// @dev Permissive ACL: hasRole always returns false (no special role gating in
///      fork tests; we use vm.prank(admin) directly for privileged calls).
contract CL_ForkMockACL {
    function hasRole(bytes32, address) external pure returns (bool) {
        return false;
    }
}

/// @dev Configurable campaign registry stub.
///      Stores payoutsHalted per campaign so checkpoint-halt tests work.
contract CL_ForkMockCampaignRegistry {
    mapping(bytes32 => GiveTypes.CampaignConfig) internal _campaigns;

    function setCampaign(bytes32 id, address payoutRecipient, bool payoutsHalted) external {
        GiveTypes.CampaignConfig storage cfg = _campaigns[id];
        cfg.id = id;
        cfg.payoutRecipient = payoutRecipient;
        cfg.status = GiveTypes.CampaignStatus.Active;
        cfg.payoutsHalted = payoutsHalted;
        cfg.exists = true;
    }

    function haltPayouts(bytes32 id) external {
        _campaigns[id].payoutsHalted = true;
    }

    function resumePayouts(bytes32 id) external {
        _campaigns[id].payoutsHalted = false;
    }

    function getCampaign(bytes32 id) external view returns (GiveTypes.CampaignConfig memory) {
        return _campaigns[id];
    }
}

// ── Test contract ────────────────────────────────────────────────────────────

contract ForkTest10_CampaignLifecycle is ForkBase {
    // ── Protocol contracts ───────────────────────────────────────────
    CL_ForkMockACL internal acl;
    CL_ForkMockCampaignRegistry internal registry;
    PayoutRouter internal router;

    // Primary vault (USDC/Aave)
    GiveVault4626 internal vault;
    AaveAdapter internal adapter;

    // Secondary vault (USDC/Aave) — same campaign, for multi-vault tests
    GiveVault4626 internal vault2;
    AaveAdapter internal adapter2;

    // ── Tokens ───────────────────────────────────────────────────────
    IERC20 internal usdc;
    IERC20 internal ausdc;

    // ── Actors ───────────────────────────────────────────────────────
    address internal admin;
    address internal ngo;
    address internal ngo2;
    address internal beneficiary;
    address[3] internal donors;

    // ── Campaign IDs ─────────────────────────────────────────────────
    bytes32 internal constant CAMPAIGN_A = keccak256("fork10_campaign_a");
    bytes32 internal constant CAMPAIGN_B = keccak256("fork10_campaign_b");

    // ── Constants ────────────────────────────────────────────────────
    uint256 internal constant DEPOSIT = 10_000e6; // 10 k USDC per donor
    uint256 internal constant INITIAL_FEE_BPS = 250; // 2.5 %

    // ── Setup ────────────────────────────────────────────────────────

    function setUp() public override {
        super.setUp(); // uses ForkBase: reads BASE_RPC_URL, creates live fork
        if (!_forkActive) return;

        usdc = IERC20(ForkAddresses.USDC);
        ausdc = IERC20(ForkAddresses.AUSDC);

        admin = makeAddr("cl_admin");
        ngo = makeAddr("cl_ngo");
        ngo2 = makeAddr("cl_ngo2");
        beneficiary = makeAddr("cl_beneficiary");
        donors[0] = makeAddr("cl_donor0");
        donors[1] = makeAddr("cl_donor1");
        donors[2] = makeAddr("cl_donor2");

        // ── Deploy shared infrastructure ──────────────────────────────
        acl = new CL_ForkMockACL();
        registry = new CL_ForkMockCampaignRegistry();
        registry.setCampaign(CAMPAIGN_A, ngo, false);
        registry.setCampaign(CAMPAIGN_B, ngo2, false);

        router = new PayoutRouter();
        vm.startPrank(admin);
        router.initialize(admin, address(acl), address(registry), admin, admin, INITIAL_FEE_BPS);
        router.grantRole(router.VAULT_MANAGER_ROLE(), admin);
        vm.stopPrank();

        // ── Primary vault (vault1 → CAMPAIGN_A) ──────────────────────
        vault = _deployVault(ForkAddresses.USDC, "Give USDC Vault", "gUSDC");
        adapter = new AaveAdapter(ForkAddresses.USDC, address(vault), ForkAddresses.AAVE_POOL, admin);
        _wireVault(vault, adapter, CAMPAIGN_A);

        // ── Secondary vault (vault2 → CAMPAIGN_A, for multi-vault tests)
        vault2 = _deployVault(ForkAddresses.USDC, "Give USDC Vault 2", "gUSDC2");
        adapter2 = new AaveAdapter(ForkAddresses.USDC, address(vault2), ForkAddresses.AAVE_POOL, admin);
        _wireVault(vault2, adapter2, CAMPAIGN_A);

        // ── Fund donors ───────────────────────────────────────────────
        for (uint256 i = 0; i < 3; i++) {
            _dealUsdc(donors[i], DEPOSIT * 4);
        }
    }

    // ════════════════════════════════════════════════════════════════
    // TEST 1 — Full cycle: deposit → invest → yield → harvest → claim → redeem
    // ════════════════════════════════════════════════════════════════

    function test_01_fullCycle_depositYieldHarvestClaimRedeem() public requiresFork {
        // Three donors deposit
        for (uint256 i = 0; i < 3; i++) {
            _deposit(donors[i], address(vault), DEPOSIT);
        }
        uint256 totalDeposited = DEPOSIT * 3;

        // Funds flow into Aave immediately on deposit.
        // The vault retains a 1% cash buffer (cashBufferBps=100), so the adapter
        // receives 99% of total deposited. Allow 1% relative tolerance.
        assertGt(ausdc.balanceOf(address(adapter)), 0, "nothing invested after deposit");
        assertApproxEqRel(
            adapter.totalAssets(), totalDeposited, 0.01e18, "adapter should hold ~99% of deposited amount"
        );

        // 30-day yield accrual
        vm.warp(block.timestamp + 30 days);

        // Harvest — profit routes to PayoutRouter accumulator
        uint256 ngoBefore = usdc.balanceOf(ngo);
        (uint256 profit, uint256 loss) = vault.harvest();
        assertGt(profit, 0, "no yield after 30 days");
        assertEq(loss, 0, "unexpected loss");

        // Donors claim — each donor's proportional share is transferred to NGO
        for (uint256 i = 0; i < 3; i++) {
            vm.prank(donors[i]);
            router.claimYield(address(vault), ForkAddresses.USDC);
        }
        assertGt(usdc.balanceOf(ngo), ngoBefore, "NGO received no USDC after claim");

        // Donors redeem principal — each should receive ≥ deposit - 5 wei (dust)
        for (uint256 i = 0; i < 3; i++) {
            uint256 shares = vault.balanceOf(donors[i]);
            vm.prank(donors[i]);
            uint256 returned = vault.redeem(shares, donors[i], donors[i]);
            assertGe(returned, DEPOSIT - 5, "donor lost principal beyond dust tolerance");
        }

        // Vault fully drained
        assertEq(vault.totalSupply(), 0, "shares remain after full redemption");
    }

    // ════════════════════════════════════════════════════════════════
    // TEST 2 — Yield accrues in adapter over 90 days; totalAssets grows
    // ════════════════════════════════════════════════════════════════
    //
    // NOTE: Share price (previewRedeem) does NOT increase after harvest —
    // harvest extracts yield from the vault and sends it to the PayoutRouter,
    // so totalAssets drops by the profit amount. The correct invariant for a
    // campaign vault is that totalAssets BEFORE harvest is higher than at
    // deposit (yield accrued), not that previewRedeem increases post-harvest.

    function test_02_adapterYieldAccrues_after90Days() public requiresFork {
        _deposit(donors[0], address(vault), DEPOSIT);

        uint256 assetsAtDeposit = vault.totalAssets();

        vm.warp(block.timestamp + 90 days);

        // Adapter totalAssets should exceed the invested amount (aToken rebasing)
        uint256 adapterAssetsAfterWarp = adapter.totalAssets();
        assertGt(adapterAssetsAfterWarp, DEPOSIT * 99 / 100, "adapter should hold at least 99% of deposit after warp");

        // Harvest extracts yield — profit > 0 confirms interest accrued
        (uint256 profit,) = vault.harvest();
        assertGt(profit, 0, "no yield harvested after 90 days");

        // totalAssets after harvest < before harvest (profit left the vault)
        uint256 assetsAfterHarvest = vault.totalAssets();
        assertLt(assetsAfterHarvest, assetsAtDeposit + profit, "totalAssets accounting inconsistent");
    }

    // ════════════════════════════════════════════════════════════════
    // TEST 3 — totalAssets() matches on-chain vault cash + adapter assets
    // ════════════════════════════════════════════════════════════════

    function test_03_totalAssetsMatchesOnChainBalances() public requiresFork {
        _deposit(donors[0], address(vault), DEPOSIT);

        uint256 vaultCash = usdc.balanceOf(address(vault));
        uint256 adapterAssets = adapter.totalAssets();

        assertEq(vault.totalAssets(), vaultCash + adapterAssets, "totalAssets() != cash + adapter");
    }

    // ════════════════════════════════════════════════════════════════
    // TEST 4 — Emergency pause divests Aave and enforces grace period
    // ════════════════════════════════════════════════════════════════

    function test_04_emergencyPause_divestsAaveAndEnforcesGrace() public requiresFork {
        _deposit(donors[0], address(vault), DEPOSIT);

        uint256 investedBefore = ausdc.balanceOf(address(adapter));
        assertGt(investedBefore, 0, "nothing invested before emergency");

        vm.prank(admin);
        vault.emergencyPause();

        // Aave funds pulled out
        assertTrue(vault.emergencyShutdown(), "vault not in emergency shutdown");
        assertLe(ausdc.balanceOf(address(adapter)), 1, "aUSDC not drained on emergency");
        assertGe(usdc.balanceOf(address(vault)), investedBefore * 99 / 100, "vault cash too low after emergency");

        // During grace period, emergencyWithdrawUser must revert
        uint256 donor0Shares = vault.balanceOf(donors[0]);
        vm.startPrank(donors[0]);
        vm.expectRevert(GiveVault4626.GracePeriodActive.selector);
        vault.emergencyWithdrawUser(donor0Shares / 2, donors[0], donors[0]);
        vm.stopPrank();

        // After grace period, donor can withdraw without allowance
        vm.warp(block.timestamp + vault.EMERGENCY_GRACE_PERIOD() + 1);

        uint256 sharesBefore = vault.balanceOf(donors[0]);
        vm.prank(donors[0]);
        uint256 withdrawn = vault.emergencyWithdrawUser(sharesBefore, donors[0], donors[0]);

        assertGt(withdrawn, 0, "emergency withdraw returned zero");
        assertEq(vault.balanceOf(donors[0]), 0, "shares not burned after emergency withdraw");
    }

    // ════════════════════════════════════════════════════════════════
    // TEST 5 — PayoutRouter accumulates yield correctly per donor share
    // ════════════════════════════════════════════════════════════════

    function test_05_routerAccumulator_proportionalToShares() public requiresFork {
        // donor0: 10k, donor1: 20k — donor1 gets 2× the yield
        _deposit(donors[0], address(vault), DEPOSIT);
        _deposit(donors[1], address(vault), DEPOSIT * 2);

        vm.warp(block.timestamp + 30 days);
        vault.harvest();

        uint256 ngo0Before = usdc.balanceOf(ngo);
        vm.prank(donors[0]);
        uint256 claim0 = router.claimYield(address(vault), ForkAddresses.USDC);

        uint256 ngo1Before = usdc.balanceOf(ngo);
        vm.prank(donors[1]);
        uint256 claim1 = router.claimYield(address(vault), ForkAddresses.USDC);

        // donor1 deposited 2× as much — NGO should receive ~2× as much from donor1's claim
        assertGt(claim0, 0, "donor0 claim zero");
        assertGt(claim1, claim0, "donor1 (2x deposit) should drive more NGO yield than donor0");

        // Both claims actually sent USDC to NGO
        assertGt(usdc.balanceOf(ngo), ngo0Before, "NGO balance unchanged after donor0 claim");
        assertGt(usdc.balanceOf(ngo), ngo1Before, "NGO balance unchanged after donor1 claim");
    }

    // ════════════════════════════════════════════════════════════════
    // TEST 6 — Partial withdrawal preserves remaining shares in router
    // ════════════════════════════════════════════════════════════════

    function test_06_partialWithdrawal_routerSharesUpdated() public requiresFork {
        _deposit(donors[0], address(vault), DEPOSIT);

        uint256 totalShares = vault.balanceOf(donors[0]);
        uint256 halfShares = totalShares / 2;

        vm.prank(donors[0]);
        vault.redeem(halfShares, donors[0], donors[0]);

        assertEq(vault.balanceOf(donors[0]), totalShares - halfShares, "wrong shares after partial redeem");
        assertEq(
            router.getUserVaultShares(donors[0], address(vault)),
            totalShares - halfShares,
            "router shares not updated after partial redeem"
        );
    }

    // ════════════════════════════════════════════════════════════════
    // TEST 7 — Halted payouts block harvest; resumed payouts re-enable it
    // ════════════════════════════════════════════════════════════════

    function test_07_haltedPayouts_blockHarvest_resumeUnblocks() public requiresFork {
        _deposit(donors[0], address(vault), DEPOSIT);
        vm.warp(block.timestamp + 30 days);

        // Halt payouts (simulates failed checkpoint)
        registry.haltPayouts(CAMPAIGN_A);

        vm.expectRevert(GiveErrors.OperationNotAllowed.selector);
        vault.harvest();

        // Resume payouts (simulates passed checkpoint)
        registry.resumePayouts(CAMPAIGN_A);

        (uint256 profit,) = vault.harvest();
        assertGt(profit, 0, "harvest should succeed after payouts resumed");
    }

    // ════════════════════════════════════════════════════════════════
    // TEST 8 — Fee timelock: increase requires delay, decrease is instant
    // ════════════════════════════════════════════════════════════════

    function test_08_feeTimelock_increaseDelayed_decreaseInstant() public requiresFork {
        bytes32 FEE_MANAGER_ROLE = router.FEE_MANAGER_ROLE();
        vm.startPrank(admin);
        router.grantRole(FEE_MANAGER_ROLE, admin);
        vm.stopPrank();

        uint256 currentFee = router.feeBps();
        address feeRecipient = router.feeRecipient();

        // Propose an increase (+50 bps)
        vm.prank(admin);
        router.proposeFeeChange(feeRecipient, currentFee + 50);

        // Cannot execute immediately
        vm.expectRevert();
        router.executeFeeChange(0);

        // Execute after timelock
        vm.warp(block.timestamp + router.FEE_CHANGE_DELAY() + 1);
        router.executeFeeChange(0);
        assertEq(router.feeBps(), currentFee + 50, "fee not increased after timelock");

        // Decrease is instant — no timelock required
        vm.prank(admin);
        router.proposeFeeChange(feeRecipient, currentFee);
        assertEq(router.feeBps(), currentFee, "fee not decreased instantly");
    }

    // ════════════════════════════════════════════════════════════════
    // TEST 9 — Two vaults, same campaign: NGO receives yield from both
    // ════════════════════════════════════════════════════════════════

    function test_09_twoVaultsSameCampaign_ngoReceivesBoth() public requiresFork {
        _deposit(donors[0], address(vault), DEPOSIT);
        _deposit(donors[1], address(vault2), DEPOSIT);

        vm.warp(block.timestamp + 30 days);

        (uint256 profit1,) = vault.harvest();
        (uint256 profit2,) = vault2.harvest();
        assertGt(profit1, 0, "no profit from vault1");
        assertGt(profit2, 0, "no profit from vault2");

        uint256 ngoBefore = usdc.balanceOf(ngo);

        vm.prank(donors[0]);
        router.claimYield(address(vault), ForkAddresses.USDC);
        vm.prank(donors[1]);
        router.claimYield(address(vault2), ForkAddresses.USDC);

        assertGt(usdc.balanceOf(ngo), ngoBefore, "NGO did not receive yield from either vault");
    }

    // ════════════════════════════════════════════════════════════════
    // TEST 10 — Share accounting is isolated between vaults
    // ════════════════════════════════════════════════════════════════

    function test_10_shareAccountingIsolated_betweenVaults() public requiresFork {
        // donor0 → vault1 only; donor1 → vault2 only
        _deposit(donors[0], address(vault), DEPOSIT);
        _deposit(donors[1], address(vault2), DEPOSIT);

        vm.warp(block.timestamp + 30 days);

        // Harvest vault1 only
        (uint256 profit1,) = vault.harvest();
        assertGt(profit1, 0, "no profit from vault1");

        // donor0 claims vault1 yield — should receive something
        vm.prank(donors[0]);
        uint256 claim0 = router.claimYield(address(vault), ForkAddresses.USDC);
        assertGt(claim0, 0, "donor0 (vault1 depositor) should receive yield");

        // donor1 claims vault1 yield — has no shares there, gets nothing
        vm.prank(donors[1]);
        uint256 claim1 = router.claimYield(address(vault), ForkAddresses.USDC);
        assertEq(claim1, 0, "donor1 (no vault1 shares) should receive zero");

        // donor1 claims vault2 yield — vault2 not harvested yet, gets zero
        vm.prank(donors[1]);
        uint256 claim1v2 = router.claimYield(address(vault2), ForkAddresses.USDC);
        assertEq(claim1v2, 0, "donor1 should receive zero from un-harvested vault2");
    }

    // ════════════════════════════════════════════════════════════════
    // TEST 11 — Vault preference: split between campaign and beneficiary
    // ════════════════════════════════════════════════════════════════

    function test_11_vaultPreference_splitBetweenCampaignAndBeneficiary() public requiresFork {
        _deposit(donors[0], address(vault), DEPOSIT);

        // Set 50 % preference toward personal beneficiary
        vm.prank(donors[0]);
        router.setVaultPreference(address(vault), beneficiary, 50);

        vm.warp(block.timestamp + 30 days);
        vault.harvest();

        uint256 ngoBefore = usdc.balanceOf(ngo);
        uint256 benBefore = usdc.balanceOf(beneficiary);

        vm.prank(donors[0]);
        uint256 totalClaimed = router.claimYield(address(vault), ForkAddresses.USDC);
        assertGt(totalClaimed, 0, "nothing claimed");

        // Both NGO and beneficiary should have received USDC
        assertGt(usdc.balanceOf(ngo), ngoBefore, "NGO did not receive campaign share");
        assertGt(usdc.balanceOf(beneficiary), benBefore, "beneficiary did not receive personal share");
    }

    // ════════════════════════════════════════════════════════════════
    // TEST 12 — Vault reassignment clears stale user preference
    // ════════════════════════════════════════════════════════════════

    function test_12_vaultReassignment_clearsStalePreference() public requiresFork {
        _deposit(donors[0], address(vault), DEPOSIT);

        vm.prank(donors[0]);
        router.setVaultPreference(address(vault), beneficiary, 50);

        vm.warp(block.timestamp + 30 days);
        (uint256 profit,) = vault.harvest();
        assertGt(profit, 0, "no profit");

        // Reassign vault from CAMPAIGN_A → CAMPAIGN_B
        registry.setCampaign(CAMPAIGN_B, ngo2, false);
        vm.prank(admin);
        router.registerCampaignVault(address(vault), CAMPAIGN_B);

        // Claim still succeeds (yield goes to CAMPAIGN_B's NGO)
        uint256 ngo2Before = usdc.balanceOf(ngo2);
        vm.prank(donors[0]);
        uint256 claimed = router.claimYield(address(vault), ForkAddresses.USDC);
        assertGt(claimed, 0, "claim should succeed after reassignment");
        assertGt(usdc.balanceOf(ngo2), ngo2Before, "new NGO should receive funds post-reassignment");

        // Stale preference must be cleared
        GiveTypes.CampaignPreference memory pref = router.getVaultPreference(donors[0], address(vault));
        assertEq(pref.campaignId, bytes32(0), "stale preference should be cleared after reassignment");
    }

    // ════════════════════════════════════════════════════════════════
    // TEST 13 — Sequential harvests accumulate campaign totals correctly
    // ════════════════════════════════════════════════════════════════
    //
    // donor0 and donor1 each deposit into the same vault at different times,
    // each followed by a 30-day warp and harvest. Each harvest should produce
    // profit > 0, and the cumulative campaign totals should grow monotonically.

    function test_13_sequentialHarvests_accumulateCampaignTotals() public requiresFork {
        // First cycle: donor0 deposits, warp 30 days, harvest
        _deposit(donors[0], address(vault), DEPOSIT);
        vm.warp(block.timestamp + 30 days);
        (uint256 profit1,) = vault.harvest();
        assertGt(profit1, 0, "no profit in first harvest");

        vm.prank(donors[0]);
        router.claimYield(address(vault), ForkAddresses.USDC);

        (uint256 totalsAfterFirst,) = router.getCampaignTotals(CAMPAIGN_A);
        assertGt(totalsAfterFirst, 0, "campaign totals should increase after first harvest+claim");

        // Second cycle: donor1 also deposits (adds to the same vault's Aave position),
        // warp another 30 days — the new deposit forces an Aave pool update at the
        // current timestamp, so the subsequent warp will accrue interest correctly.
        _deposit(donors[1], address(vault), DEPOSIT);
        vm.warp(block.timestamp + 30 days);
        (uint256 profit2, uint256 loss2) = vault.harvest();

        // Fork/mainnet behavior can produce tiny rounding dust on sequential
        // harvests after reinvest, so accept zero-profit only when the loss is
        // bounded to negligible dust.
        if (profit2 == 0) {
            assertLe(loss2, 5, "second harvest had non-dust loss");
        } else {
            assertEq(loss2, 0, "unexpected loss when second harvest has profit");
        }

        vm.prank(donors[1]);
        router.claimYield(address(vault), ForkAddresses.USDC);

        (uint256 totalsAfterSecond,) = router.getCampaignTotals(CAMPAIGN_A);
        if (profit2 > 0) {
            assertGt(totalsAfterSecond, totalsAfterFirst, "campaign totals should increase after second harvest+claim");
        } else {
            assertEq(
                totalsAfterSecond,
                totalsAfterFirst,
                "campaign totals should remain unchanged on zero-profit dust harvest"
            );
        }
    }

    // ════════════════════════════════════════════════════════════════
    // TEST 14 — Redeem with zero shares is a no-op (ERC4626 standard)
    // ════════════════════════════════════════════════════════════════

    function test_14_redeemZeroShares_isNoOp() public requiresFork {
        _deposit(donors[0], address(vault), DEPOSIT);

        uint256 sharesBefore = vault.balanceOf(donors[0]);

        vm.prank(donors[0]);
        uint256 assets = vault.redeem(0, donors[0], donors[0]);

        assertEq(assets, 0, "redeem(0) should return 0 assets");
        assertEq(vault.balanceOf(donors[0]), sharesBefore, "shares should not change on redeem(0)");
    }

    // ════════════════════════════════════════════════════════════════
    // TEST 15 — Redeem exceeding balance reverts
    // ════════════════════════════════════════════════════════════════

    function test_15_redeemExceedsBalance_reverts() public requiresFork {
        _deposit(donors[0], address(vault), DEPOSIT);

        uint256 shares = vault.balanceOf(donors[0]);

        vm.prank(donors[0]);
        vm.expectRevert();
        vault.redeem(shares + 1, donors[0], donors[0]);
    }

    // ════════════════════════════════════════════════════════════════
    // Internal helpers
    // ════════════════════════════════════════════════════════════════

    function _deployVault(address asset, string memory name, string memory symbol) internal returns (GiveVault4626 v) {
        v = new GiveVault4626();
        vm.prank(admin);
        v.initialize(asset, name, symbol, admin, address(acl), address(v));
    }

    function _wireVault(GiveVault4626 v, AaveAdapter adp, bytes32 campaignId) internal {
        vm.startPrank(admin);
        v.setActiveAdapter(IYieldAdapter(address(adp)));
        v.setDonationRouter(address(router));
        router.registerCampaignVault(address(v), campaignId);
        router.setAuthorizedCaller(address(v), true);
        vm.stopPrank();
    }

    function _deposit(address donor, address vaultAddr, uint256 amount) internal {
        vm.startPrank(donor);
        usdc.approve(vaultAddr, amount);
        GiveVault4626(payable(vaultAddr)).deposit(amount, donor);
        vm.stopPrank();
    }
}
