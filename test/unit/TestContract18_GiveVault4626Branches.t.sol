// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title   TestContract18_GiveVault4626Branches
 * @author  GIVE Labs
 * @notice  Comprehensive test suite for GiveVault4626.
 * @dev     Covers initialisation, deposits/withdrawals, adapter wiring, harvest pipeline,
 *          emergency system, native ETH helpers, cash-buffer enforcement, and access control.
 *
 *          Structure:
 *          - Cases 01–06   Emergency system & pause guards
 *          - Cases 07–12   Adapter management
 *          - Cases 13–18   Harvest pipeline (functional correctness)
 *          - Cases 19–23   Cash management & risk limits
 *          - Cases 24–32   Native ETH helpers (depositETH / redeemETH / withdrawETH)
 *          - Cases 33–38   Admin operations & configuration
 *          - Cases 39–41   Guard rails & access control
 */

import "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {GiveVault4626} from "../../src/vault/GiveVault4626.sol";
import {IYieldAdapter} from "../../src/interfaces/IYieldAdapter.sol";
import {ACLManager} from "../../src/governance/ACLManager.sol";
import {PayoutRouter} from "../../src/payout/PayoutRouter.sol";
import {MockERC20} from "../../src/mocks/MockERC20.sol";
import {GiveErrors} from "../../src/utils/GiveErrors.sol";
import {GiveTypes} from "../../src/types/GiveTypes.sol";

// ─── Mocks ────────────────────────────────────────────────────────────────────

/// @dev Controllable adapter: harvest returns configurable profit; divest honours returnFraction.
contract BranchTestAdapter is IYieldAdapter {
    IERC20 public immutable _asset;
    address public immutable _vault;

    uint256 public invested;
    uint256 public returnFraction = 10_000; // 100%
    uint256 public harvestProfit;

    // For mismatch stubs
    address public assetOverride;
    address public vaultOverride;

    constructor(address asset_, address vault_) {
        _asset = IERC20(asset_);
        _vault = vault_;
        assetOverride = asset_;
        vaultOverride = vault_;
    }

    function setReturnFraction(uint256 bps) external {
        returnFraction = bps;
    }

    function setHarvestProfit(uint256 profit) external {
        harvestProfit = profit;
    }

    function asset() external view override returns (IERC20) {
        return IERC20(assetOverride);
    }

    function vault() external view override returns (address) {
        return vaultOverride;
    }

    function totalAssets() external view override returns (uint256) {
        return invested;
    }

    function invest(uint256 amount) external override {
        invested += amount;
    }

    function divest(uint256 amount) external override returns (uint256 returned) {
        returned = (amount * returnFraction) / 10_000;
        if (returned > invested) returned = invested;
        invested -= returned;
        if (returned > 0) _asset.transfer(_vault, returned);
    }

    function harvest() external override returns (uint256 profit, uint256 loss) {
        profit = harvestProfit;
        loss = 0;
        harvestProfit = 0;
        if (profit > 0) _asset.transfer(msg.sender, profit);
    }

    function emergencyWithdraw() external override returns (uint256 returned) {
        returned = invested;
        invested = 0;
        if (returned > 0) _asset.transfer(_vault, returned);
    }
}

/// @dev Adapter that reports the wrong asset (for mismatch tests).
contract WrongAssetAdapter is IYieldAdapter {
    address public immutable wrongAsset;
    address public immutable vaultAddr;

    constructor(address wrong, address vault_) {
        wrongAsset = wrong;
        vaultAddr = vault_;
    }

    function asset() external view override returns (IERC20) {
        return IERC20(wrongAsset);
    }

    function vault() external view override returns (address) {
        return vaultAddr;
    }

    function totalAssets() external pure override returns (uint256) {
        return 0;
    }

    function invest(uint256) external override {}

    function divest(uint256) external pure override returns (uint256) {
        return 0;
    }

    function harvest() external pure override returns (uint256, uint256) {
        return (0, 0);
    }

    function emergencyWithdraw() external pure override returns (uint256) {
        return 0;
    }
}

/// @dev Adapter that reports the wrong vault (for mismatch tests).
contract WrongVaultAdapter is IYieldAdapter {
    address public immutable assetAddr;
    address public immutable wrongVault;

    constructor(address asset_, address wrong) {
        assetAddr = asset_;
        wrongVault = wrong;
    }

    function asset() external view override returns (IERC20) {
        return IERC20(assetAddr);
    }

    function vault() external view override returns (address) {
        return wrongVault;
    }

    function totalAssets() external pure override returns (uint256) {
        return 0;
    }

    function invest(uint256) external override {}

    function divest(uint256) external pure override returns (uint256) {
        return 0;
    }

    function harvest() external pure override returns (uint256, uint256) {
        return (0, 0);
    }

    function emergencyWithdraw() external pure override returns (uint256) {
        return 0;
    }
}

/// @dev WETH-like token for native ETH roundtrip tests.
contract MockWETH is MockERC20 {
    constructor() MockERC20("Wrapped Ether", "WETH", 18) {}

    function deposit() external payable {
        _mint(msg.sender, msg.value);
    }

    function withdraw(uint256 amount) external {
        _burn(msg.sender, amount);
        (bool ok,) = payable(msg.sender).call{value: amount}("");
        require(ok, "ETH_TRANSFER_FAILED");
    }

    receive() external payable {}
}

/// @dev Minimal PayoutRouter ACL — always returns false (force local role storage).
contract MockACL18 {
    function hasRole(bytes32, address) external pure returns (bool) {
        return false;
    }
}

/// @dev Minimal campaign registry for wired harvest tests.
contract MockRegistry18 {
    address public payoutRecipient;

    constructor(address r) {
        payoutRecipient = r;
    }

    function getCampaign(bytes32 id) external view returns (GiveTypes.CampaignConfig memory) {
        uint256[49] memory emptyGap;
        return GiveTypes.CampaignConfig({
            id: id,
            proposer: address(0),
            curator: address(0),
            payoutRecipient: payoutRecipient,
            vault: address(0),
            strategyId: bytes32(0),
            metadataHash: bytes32(0),
            targetStake: 0,
            minStake: 0,
            totalStaked: 0,
            lockedStake: 0,
            initialDeposit: 0,
            fundraisingStart: 0,
            fundraisingEnd: 0,
            createdAt: 0,
            updatedAt: 0,
            status: GiveTypes.CampaignStatus.Active,
            lockProfile: bytes32(0),
            checkpointQuorumBps: 0,
            checkpointVotingDelay: 0,
            checkpointVotingPeriod: 0,
            exists: true,
            payoutsHalted: false,
            __gap: emptyGap
        });
    }
}

// ─── Test contract ────────────────────────────────────────────────────────────

contract TestContract18_GiveVault4626Branches is Test {
    GiveVault4626 public impl;
    ACLManager public acl;
    MockERC20 public usdc;

    address public admin;
    address public user1;
    address public user2;

    uint256 public constant DEPOSIT = 1000e6;

    function setUp() public {
        admin = makeAddr("admin");
        user1 = makeAddr("user1");
        user2 = makeAddr("user2");

        usdc = new MockERC20("USD Coin", "USDC", 6);

        ACLManager aclImpl = new ACLManager();
        bytes memory aclInit = abi.encodeWithSelector(ACLManager.initialize.selector, admin, admin);
        acl = ACLManager(address(new ERC1967Proxy(address(aclImpl), aclInit)));

        impl = new GiveVault4626();
    }

    // ── helpers ──────────────────────────────────────────────────────────────

    function _deployVault() internal returns (GiveVault4626) {
        bytes memory init = abi.encodeCall(
            GiveVault4626.initialize, (address(usdc), "Test Vault", "tvUSDC", admin, address(acl), address(impl))
        );
        return GiveVault4626(payable(address(new ERC1967Proxy(address(impl), init))));
    }

    function _deployWETHVault() internal returns (GiveVault4626, MockWETH) {
        MockWETH weth = new MockWETH();
        GiveVault4626 localImpl = new GiveVault4626();
        bytes memory init = abi.encodeCall(
            GiveVault4626.initialize, (address(weth), "WETH Vault", "tvWETH", admin, address(acl), address(localImpl))
        );
        GiveVault4626 v = GiveVault4626(payable(address(new ERC1967Proxy(address(localImpl), init))));
        vm.prank(admin);
        v.setWrappedNative(address(weth));
        return (v, weth);
    }

    /// @dev Deploy a minimal PayoutRouter wired to `v` under `testCampaignId`.
    function _deployWiredRouter(GiveVault4626 v, bytes32 testCampaignId, address ngo)
        internal
        returns (PayoutRouter router)
    {
        MockACL18 mockAcl = new MockACL18();
        MockRegistry18 mockReg = new MockRegistry18(ngo);

        router = new PayoutRouter();
        vm.prank(admin);
        router.initialize(admin, address(mockAcl), address(mockReg), admin, admin, 0);

        vm.startPrank(admin);
        router.grantRole(router.VAULT_MANAGER_ROLE(), admin);
        router.registerCampaignVault(address(v), testCampaignId);
        router.setAuthorizedCaller(address(v), true);
        vm.stopPrank();
    }

    function _fund(address user, uint256 amount) internal {
        usdc.mint(user, amount);
    }

    function _deposit(GiveVault4626 v, address user, uint256 amount) internal returns (uint256 shares) {
        _fund(user, amount);
        vm.startPrank(user);
        usdc.approve(address(v), amount);
        shares = v.deposit(amount, user);
        vm.stopPrank();
    }

    // ============================================
    // CASES 01–06  Emergency system & pause guards
    // ============================================

    function test_Contract18_Case01_emergencyPause_blocksDeposit() public {
        GiveVault4626 v = _deployVault();
        _fund(user1, DEPOSIT);

        vm.prank(admin);
        v.emergencyPause();

        vm.startPrank(user1);
        usdc.approve(address(v), DEPOSIT);
        vm.expectRevert();
        v.deposit(DEPOSIT, user1);
        vm.stopPrank();
    }

    function test_Contract18_Case02_gracePeriodExpired_blocksWithdraw() public {
        GiveVault4626 v = _deployVault();
        uint256 shares = _deposit(v, user1, DEPOSIT);

        vm.prank(admin);
        v.emergencyPause();
        vm.warp(block.timestamp + v.EMERGENCY_GRACE_PERIOD() + 1);

        vm.prank(user1);
        vm.expectRevert(GiveVault4626.GracePeriodExpired.selector);
        v.withdraw(DEPOSIT, user1, user1);

        vm.prank(user1);
        vm.expectRevert(GiveVault4626.GracePeriodExpired.selector);
        v.redeem(shares, user1, user1);
    }

    function test_Contract18_Case03_withinGracePeriod_withdrawAllowed() public {
        GiveVault4626 v = _deployVault();
        _deposit(v, user1, DEPOSIT);

        vm.prank(admin);
        v.emergencyPause();
        vm.warp(block.timestamp + v.EMERGENCY_GRACE_PERIOD() - 1);

        vm.prank(user1);
        v.withdraw(DEPOSIT, user1, user1);

        assertEq(v.balanceOf(user1), 0);
        assertEq(usdc.balanceOf(user1), DEPOSIT);
    }

    function test_Contract18_Case04_emergencyWithdrawUser_gracePeriodActive_reverts() public {
        GiveVault4626 v = _deployVault();
        uint256 shares = _deposit(v, user1, DEPOSIT);

        vm.prank(admin);
        v.emergencyPause();

        vm.prank(user1);
        vm.expectRevert(GiveVault4626.GracePeriodActive.selector);
        v.emergencyWithdrawUser(shares, user1, user1);
    }

    function test_Contract18_Case05_emergencyWithdrawUser_insufficientAllowance_reverts() public {
        GiveVault4626 v = _deployVault();
        uint256 shares = _deposit(v, user1, DEPOSIT);

        vm.prank(admin);
        v.emergencyPause();
        vm.warp(block.timestamp + v.EMERGENCY_GRACE_PERIOD() + 1);

        vm.prank(user2);
        vm.expectRevert(GiveVault4626.InsufficientAllowance.selector);
        v.emergencyWithdrawUser(shares, user2, user1);
    }

    function test_Contract18_Case06_emergencyWithdrawUser_allowanceDecremented() public {
        GiveVault4626 v = _deployVault();
        uint256 shares = _deposit(v, user1, DEPOSIT);

        vm.prank(admin);
        v.emergencyPause();
        vm.warp(block.timestamp + v.EMERGENCY_GRACE_PERIOD() + 1);

        vm.prank(user1);
        v.approve(user2, shares);

        vm.prank(user2);
        v.emergencyWithdrawUser(shares, user2, user1);

        assertEq(v.allowance(user1, user2), 0, "allowance must be consumed");
        assertEq(v.balanceOf(user1), 0, "shares must be burned");
        assertGt(usdc.balanceOf(user2), 0, "user2 must receive assets");
    }

    // ============================================
    // CASES 07–12  Adapter management
    // ============================================

    function test_Contract18_Case07_setActiveAdapter_wrongAsset_reverts() public {
        GiveVault4626 v = _deployVault();
        WrongAssetAdapter bad = new WrongAssetAdapter(makeAddr("wrongToken"), address(v));

        vm.prank(admin);
        vm.expectRevert(GiveVault4626.InvalidAsset.selector);
        v.setActiveAdapter(IYieldAdapter(address(bad)));
    }

    function test_Contract18_Case08_setActiveAdapter_wrongVault_reverts() public {
        GiveVault4626 v = _deployVault();
        WrongVaultAdapter bad = new WrongVaultAdapter(address(usdc), makeAddr("wrongVault"));

        vm.prank(admin);
        vm.expectRevert(GiveVault4626.InvalidAdapter.selector);
        v.setActiveAdapter(IYieldAdapter(address(bad)));
    }

    function test_Contract18_Case09_setActiveAdapter_validAdapter_accepted() public {
        GiveVault4626 v = _deployVault();
        BranchTestAdapter adapter = new BranchTestAdapter(address(usdc), address(v));

        vm.prank(admin);
        v.setActiveAdapter(IYieldAdapter(address(adapter)));

        assertEq(address(v.activeAdapter()), address(adapter), "adapter must be stored");
    }

    function test_Contract18_Case10_setActiveAdapter_zeroAddress_clearsAdapter() public {
        GiveVault4626 v = _deployVault();
        BranchTestAdapter adapter = new BranchTestAdapter(address(usdc), address(v));

        vm.startPrank(admin);
        v.setActiveAdapter(IYieldAdapter(address(adapter)));
        v.setActiveAdapter(IYieldAdapter(address(0)));
        vm.stopPrank();

        assertEq(address(v.activeAdapter()), address(0), "adapter must be cleared");
    }

    function test_Contract18_Case11_forceClearAdapter_adapterHasFunds_reverts() public {
        GiveVault4626 v = _deployVault();
        BranchTestAdapter adapter = new BranchTestAdapter(address(usdc), address(v));

        vm.prank(admin);
        v.setActiveAdapter(IYieldAdapter(address(adapter)));

        usdc.mint(address(adapter), 1e6);
        adapter.invest(1e6);
        uint256 adapterFunds = adapter.totalAssets();

        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(GiveVault4626.AdapterHasFunds.selector, adapterFunds));
        v.forceClearAdapter();
    }

    function test_Contract18_Case12_emergencyWithdrawFromAdapter_drainsAdapterCreditsVault() public {
        GiveVault4626 v = _deployVault();
        BranchTestAdapter adapter = new BranchTestAdapter(address(usdc), address(v));

        vm.prank(admin);
        v.setActiveAdapter(IYieldAdapter(address(adapter)));

        uint256 investedAmount = DEPOSIT;
        usdc.mint(address(adapter), investedAmount);
        adapter.invest(investedAmount);

        assertEq(adapter.totalAssets(), investedAmount);
        uint256 cashBefore = usdc.balanceOf(address(v));

        vm.prank(admin);
        uint256 withdrawn = v.emergencyWithdrawFromAdapter();

        assertEq(withdrawn, investedAmount, "withdrawn must equal adapter balance");
        assertEq(adapter.totalAssets(), 0, "adapter must be empty");
        assertEq(usdc.balanceOf(address(v)), cashBefore + investedAmount, "vault cash must increase");
    }

    // ============================================
    // CASES 13–18  Harvest pipeline (functional correctness)
    // ============================================

    function test_Contract18_Case13_harvest_adapterNotSet_reverts() public {
        GiveVault4626 v = _deployVault();
        vm.expectRevert(GiveVault4626.AdapterNotSet.selector);
        v.harvest();
    }

    function test_Contract18_Case14_harvest_missingDonationRouter_reverts() public {
        GiveVault4626 v = _deployVault();
        BranchTestAdapter adapter = new BranchTestAdapter(address(usdc), address(v));

        vm.prank(admin);
        v.setActiveAdapter(IYieldAdapter(address(adapter)));

        vm.expectRevert(GiveVault4626.InvalidConfiguration.selector);
        v.harvest();
    }

    function test_Contract18_Case15_harvest_zeroProfitPath_noTransfer() public {
        GiveVault4626 v = _deployVault();
        BranchTestAdapter adapter = new BranchTestAdapter(address(usdc), address(v));
        bytes32 cid = keccak256("harvest-zero");
        PayoutRouter router = _deployWiredRouter(v, cid, makeAddr("ngo15"));

        vm.startPrank(admin);
        v.setActiveAdapter(IYieldAdapter(address(adapter)));
        v.setDonationRouter(address(router));
        vm.stopPrank();

        _deposit(v, user1, DEPOSIT);

        uint256 routerBefore = usdc.balanceOf(address(router));
        (uint256 profit, uint256 loss) = v.harvest(); // adapter returns (0, 0)

        assertEq(profit, 0);
        assertEq(loss, 0);
        assertEq(usdc.balanceOf(address(router)), routerBefore, "no transfer on zero profit");
    }

    function test_Contract18_Case16_harvest_wiredRouter_claimYield_fullPipeline() public {
        GiveVault4626 v = _deployVault();
        BranchTestAdapter adapter = new BranchTestAdapter(address(usdc), address(v));
        address ngo = makeAddr("ngo16");
        bytes32 cid = keccak256("harvest-pipeline");
        PayoutRouter router = _deployWiredRouter(v, cid, ngo);

        vm.startPrank(admin);
        v.setActiveAdapter(IYieldAdapter(address(adapter)));
        v.setDonationRouter(address(router));
        vm.stopPrank();

        _deposit(v, user1, DEPOSIT);

        assertGt(router.getUserVaultShares(user1, address(v)), 0, "router must track user shares after deposit");

        uint256 profit = 100e6;
        usdc.mint(address(adapter), profit);
        adapter.setHarvestProfit(profit);

        v.harvest();

        uint256 pending = router.getPendingYield(user1, address(v), address(usdc));
        assertGt(pending, 0, "user must have pending yield after harvest");

        uint256 ngoBefore = usdc.balanceOf(ngo);
        vm.prank(user1);
        uint256 claimed = router.claimYield(address(v), address(usdc));

        assertEq(claimed, profit, "claimed must equal harvested profit (zero fee)");
        assertApproxEqAbs(usdc.balanceOf(ngo) - ngoBefore, profit, 1, "NGO must receive all yield");
    }

    function test_Contract18_Case17_harvest_updatesHarvestStats() public {
        GiveVault4626 v = _deployVault();
        BranchTestAdapter adapter = new BranchTestAdapter(address(usdc), address(v));
        bytes32 cid = keccak256("stats");
        PayoutRouter router = _deployWiredRouter(v, cid, makeAddr("ngo17"));

        vm.startPrank(admin);
        v.setActiveAdapter(IYieldAdapter(address(adapter)));
        v.setDonationRouter(address(router));
        vm.stopPrank();

        _deposit(v, user1, DEPOSIT);

        assertEq(v.totalProfit(), 0);
        assertEq(v.totalLoss(), 0);

        uint256 profit = 50e6;
        usdc.mint(address(adapter), profit);
        adapter.setHarvestProfit(profit);

        (uint256 actualProfit,) = v.harvest();
        assertEq(actualProfit, profit, "harvest must return correct profit");
        assertEq(v.totalProfit(), profit, "totalProfit must accumulate");
        assertEq(v.totalLoss(), 0);

        (uint256 tp, uint256 tl, uint256 lastHarvest) = v.getHarvestStats();
        assertEq(tp, profit);
        assertEq(tl, 0);
        assertGt(lastHarvest, 0, "lastHarvestTime must be set");
    }

    function test_Contract18_Case18_harvest_sharePriceNonDecreasing() public {
        GiveVault4626 v = _deployVault();
        BranchTestAdapter adapter = new BranchTestAdapter(address(usdc), address(v));
        bytes32 cid = keccak256("price");
        PayoutRouter router = _deployWiredRouter(v, cid, makeAddr("ngo18"));

        vm.startPrank(admin);
        v.setActiveAdapter(IYieldAdapter(address(adapter)));
        v.setDonationRouter(address(router));
        vm.stopPrank();

        uint256 shares = _deposit(v, user1, DEPOSIT);
        uint256 priceBefore = v.previewRedeem(shares);

        uint256 profit = 100e6;
        usdc.mint(address(adapter), profit);
        adapter.setHarvestProfit(profit);
        v.harvest();

        // Profit moves to router (not vault), so vault price is stable — must not decrease
        assertGe(v.previewRedeem(shares), priceBefore, "share price must not decrease after harvest");
    }

    // ============================================
    // CASES 19–23  Cash management & risk limits
    // ============================================

    function test_Contract18_Case19_deposit_invests_excess_above_cashBuffer() public {
        GiveVault4626 v = _deployVault();
        BranchTestAdapter adapter = new BranchTestAdapter(address(usdc), address(v));

        uint256 BUFFER_BPS = 500; // 5%
        vm.startPrank(admin);
        v.setActiveAdapter(IYieldAdapter(address(adapter)));
        v.setCashBufferBps(BUFFER_BPS);
        vm.stopPrank();

        _deposit(v, user1, DEPOSIT);

        uint256 totalAssets = v.totalAssets();
        uint256 expectedCash = (totalAssets * BUFFER_BPS) / 10_000;
        assertApproxEqAbs(usdc.balanceOf(address(v)), expectedCash, 1, "vault cash must equal buffer target");
        assertApproxEqAbs(adapter.totalAssets(), totalAssets - expectedCash, 1, "adapter must hold excess");
    }

    function test_Contract18_Case20_ensureSufficientCash_sufficientCash_skipsDivest() public {
        GiveVault4626 v = _deployVault();
        uint256 shares = _deposit(v, user1, DEPOSIT);

        // No active adapter — all funds are cash; divest path never reached
        vm.prank(user1);
        v.redeem(shares / 2, user1, user1);

        assertGt(usdc.balanceOf(user1), 0, "user must receive cash");
        assertEq(address(v.activeAdapter()), address(0));
    }

    function test_Contract18_Case21_ensureSufficientCash_excessiveLoss_reverts() public {
        GiveVault4626 v = _deployVault();
        BranchTestAdapter adapter = new BranchTestAdapter(address(usdc), address(v));

        vm.startPrank(admin);
        v.setActiveAdapter(IYieldAdapter(address(adapter)));
        v.setCashBufferBps(0);
        v.setMaxLossBps(100); // 1% max loss
        vm.stopPrank();

        _deposit(v, user1, DEPOSIT);

        uint256 cash = usdc.balanceOf(address(v));
        usdc.transfer(address(adapter), cash);
        adapter.invest(cash);

        adapter.setReturnFraction(9000); // returns only 90% → 10% loss

        uint256 shares = v.balanceOf(user1);
        vm.prank(user1);
        vm.expectRevert(); // ExcessiveLoss
        v.redeem(shares, user1, user1);
    }

    function test_Contract18_Case22_depositLimit_enforcedAfter_syncRiskLimits() public {
        GiveVault4626 v = _deployVault();
        uint256 LIMIT = 500e6;

        vm.prank(admin);
        v.syncRiskLimits(keccak256("risk1"), LIMIT, 0);

        _deposit(v, user1, LIMIT); // exactly at limit — should succeed

        _fund(user2, 1);
        vm.startPrank(user2);
        usdc.approve(address(v), 1);
        vm.expectRevert();
        v.deposit(1, user2); // one wei over limit
        vm.stopPrank();
    }

    function test_Contract18_Case23_resumeFromEmergency_reenablesDeposits() public {
        GiveVault4626 v = _deployVault();

        vm.prank(admin);
        v.emergencyPause();
        assertTrue(v.paused());
        assertTrue(v.investPaused());

        vm.prank(admin);
        v.resumeFromEmergency();

        assertFalse(v.paused());
        assertFalse(v.investPaused());
        assertFalse(v.emergencyShutdown());

        _deposit(v, user1, DEPOSIT);
        assertGt(v.balanceOf(user1), 0, "user must have shares after resume");
    }

    // ============================================
    // CASES 24–32  Native ETH helpers
    // ============================================

    function test_Contract18_Case24_depositETH_noWrappedNative_reverts() public {
        GiveVault4626 v = _deployVault();
        vm.deal(user1, 1 ether);
        vm.prank(user1);
        vm.expectRevert(GiveVault4626.InvalidConfiguration.selector);
        v.depositETH{value: 1 ether}(user1, 0);
    }

    function test_Contract18_Case25_depositETH_zeroMsgValue_reverts() public {
        GiveVault4626 v = _deployVault();
        vm.prank(admin);
        v.setWrappedNative(address(usdc)); // usdc == asset so passes the check

        vm.prank(user1);
        vm.expectRevert(GiveVault4626.InvalidAmount.selector);
        v.depositETH{value: 0}(user1, 0);
    }

    function test_Contract18_Case26_depositETH_zeroReceiver_reverts() public {
        GiveVault4626 v = _deployVault();
        vm.prank(admin);
        v.setWrappedNative(address(usdc));

        vm.deal(user1, 1 ether);
        vm.prank(user1);
        vm.expectRevert(GiveVault4626.InvalidReceiver.selector);
        v.depositETH{value: 1 ether}(address(0), 0);
    }

    function test_Contract18_Case27_depositETH_fullAccounting() public {
        (GiveVault4626 v, MockWETH weth) = _deployWETHVault();

        uint256 ethAmount = 1 ether;
        vm.deal(user1, ethAmount);

        uint256 wethBefore = weth.balanceOf(address(v));
        vm.prank(user1);
        uint256 shares = v.depositETH{value: ethAmount}(user1, 0);

        assertGt(shares, 0, "shares must be minted");
        assertEq(v.balanceOf(user1), shares, "balance must match return value");
        assertEq(weth.balanceOf(address(v)) - wethBefore, ethAmount, "vault must hold WETH equal to deposited ETH");
        assertEq(user1.balance, 0, "user ETH must be consumed");
    }

    function test_Contract18_Case28_redeemETH_noWrappedNative_reverts() public {
        GiveVault4626 v = _deployVault();
        vm.prank(user1);
        vm.expectRevert(GiveVault4626.InvalidConfiguration.selector);
        v.redeemETH(100, user1, user1, 0);
    }

    function test_Contract18_Case29_redeemETH_zeroShares_reverts() public {
        GiveVault4626 v = _deployVault();
        vm.prank(admin);
        v.setWrappedNative(address(usdc));

        vm.prank(user1);
        vm.expectRevert(GiveVault4626.InvalidAmount.selector);
        v.redeemETH(0, user1, user1, 0);
    }

    function test_Contract18_Case30_redeemETH_roundtrip() public {
        (GiveVault4626 v, MockWETH weth) = _deployWETHVault();
        vm.deal(address(weth), 10 ether); // back WETH withdrawals

        uint256 ethAmount = 1 ether;
        vm.deal(user1, ethAmount);

        vm.prank(user1);
        uint256 shares = v.depositETH{value: ethAmount}(user1, 0);

        uint256 ethBefore = user1.balance;
        vm.prank(user1);
        uint256 assets = v.redeemETH(shares, user1, user1, 0);

        assertApproxEqAbs(assets, ethAmount, 1, "assets returned must match deposited ETH");
        assertApproxEqAbs(user1.balance - ethBefore, ethAmount, 1, "user must receive ETH");
        assertEq(v.balanceOf(user1), 0, "shares must be fully burned");
    }

    function test_Contract18_Case31_withdrawETH_noWrappedNative_reverts() public {
        GiveVault4626 v = _deployVault();
        vm.prank(user1);
        vm.expectRevert(GiveVault4626.InvalidConfiguration.selector);
        v.withdrawETH(100, user1, user1, type(uint256).max);
    }

    function test_Contract18_Case32_withdrawETH_roundtrip() public {
        (GiveVault4626 v, MockWETH weth) = _deployWETHVault();
        vm.deal(address(weth), 10 ether);

        uint256 ethAmount = 1 ether;
        vm.deal(user1, ethAmount);

        vm.prank(user1);
        v.depositETH{value: ethAmount}(user1, 0);

        uint256 ethBefore = user1.balance;
        uint256 sharesBefore = v.balanceOf(user1);

        vm.prank(user1);
        uint256 burntShares = v.withdrawETH(ethAmount, user1, user1, type(uint256).max);

        assertApproxEqAbs(user1.balance - ethBefore, ethAmount, 1, "user must receive ETH");
        assertEq(v.balanceOf(user1), 0, "all shares must be burned");
        assertEq(burntShares, sharesBefore, "burnt shares must equal held shares");
    }

    // ============================================
    // CASES 33–38  Admin operations & configuration
    // ============================================

    function test_Contract18_Case33_setWrappedNative_zeroAndWrongAsset_revert() public {
        GiveVault4626 v = _deployVault();

        vm.prank(admin);
        vm.expectRevert();
        v.setWrappedNative(address(0));

        vm.prank(admin);
        vm.expectRevert(GiveVault4626.InvalidConfiguration.selector);
        v.setWrappedNative(makeAddr("wrongWrapped"));
    }

    function test_Contract18_Case34_setDonationRouter_zero_reverts() public {
        GiveVault4626 v = _deployVault();

        vm.prank(admin);
        vm.expectRevert();
        v.setDonationRouter(address(0));
    }

    function test_Contract18_Case35_setCashBufferBps_aboveMax_reverts() public {
        GiveVault4626 v = _deployVault();
        uint256 aboveMax = v.MAX_CASH_BUFFER_BPS() + 1; // read before prank

        vm.prank(admin);
        vm.expectRevert(GiveVault4626.CashBufferTooHigh.selector);
        v.setCashBufferBps(aboveMax);
    }

    function test_Contract18_Case36_getConfiguration_returnsCorrectValues() public {
        GiveVault4626 v = _deployVault();

        (uint256 cashBuffer, uint256 slippage, uint256 maxLoss, bool investPausedStatus, bool harvestPausedStatus) =
            v.getConfiguration();

        assertEq(cashBuffer, 100, "default cash buffer is 1%");
        assertEq(slippage, 50, "default slippage is 0.5%");
        assertEq(maxLoss, 50, "default maxLoss is 0.5%");
        assertFalse(investPausedStatus);
        assertFalse(harvestPausedStatus);
    }

    function test_Contract18_Case37_emergencyWithdrawFromAdapter_noAdapter_reverts() public {
        GiveVault4626 v = _deployVault();

        vm.prank(admin);
        vm.expectRevert(GiveVault4626.AdapterNotSet.selector);
        v.emergencyWithdrawFromAdapter();
    }

    function test_Contract18_Case38_receive_reverts_for_nonWETH_sender() public {
        (GiveVault4626 v,) = _deployWETHVault();

        vm.deal(user1, 1 ether);
        vm.prank(user1);
        (bool ok,) = payable(address(v)).call{value: 1 ether}("");
        assertFalse(ok, "receive() must reject ETH from non-WETH sender");
    }

    // ============================================
    // CASES 39–41  Guard rails & access control
    // ============================================

    function test_Contract18_Case39_emergencyWithdrawUser_notInEmergency_reverts() public {
        GiveVault4626 v = _deployVault();
        uint256 shares = _deposit(v, user1, DEPOSIT);

        vm.prank(user1);
        vm.expectRevert(GiveVault4626.NotInEmergency.selector);
        v.emergencyWithdrawUser(shares, user1, user1);
    }

    function test_Contract18_Case40_emergencyWithdrawUser_zeroReceiver_reverts() public {
        GiveVault4626 v = _deployVault();

        vm.prank(user1);
        vm.expectRevert();
        v.emergencyWithdrawUser(1, address(0), user1);
    }

    function test_Contract18_Case41_emergencyWithdrawUser_zeroShares_reverts() public {
        GiveVault4626 v = _deployVault();

        vm.prank(admin);
        v.emergencyPause();
        vm.warp(block.timestamp + v.EMERGENCY_GRACE_PERIOD() + 1);

        vm.prank(user1);
        vm.expectRevert(GiveVault4626.ZeroAmount.selector);
        v.emergencyWithdrawUser(0, user1, user1);
    }
}
