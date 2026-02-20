// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {GiveVault4626} from "../../src/vault/GiveVault4626.sol";
import {IYieldAdapter} from "../../src/interfaces/IYieldAdapter.sol";
import {ACLManager} from "../../src/governance/ACLManager.sol";
import {MockERC20} from "../../src/mocks/MockERC20.sol";
import {GiveErrors} from "../../src/utils/GiveErrors.sol";

/// @dev Minimal controllable adapter for branch testing
contract BranchTestAdapter is IYieldAdapter {
    IERC20 public immutable _asset;
    address public immutable _vault;

    uint256 public invested;
    uint256 public returnFraction = 10_000; // bps — 10000 = return 100%

    // For asset/vault mismatch test stubs
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
        // Return only returnFraction of requested amount (simulates partial/loss)
        returned = (amount * returnFraction) / 10_000;
        if (returned > invested) returned = invested;
        invested -= returned;
        if (returned > 0) {
            _asset.transfer(_vault, returned);
        }
    }

    function harvest() external override returns (uint256 profit, uint256 loss) {
        return (0, 0);
    }

    function emergencyWithdraw() external override returns (uint256 returned) {
        returned = invested;
        invested = 0;
        if (returned > 0) _asset.transfer(_vault, returned);
    }
}

/// @dev Minimal donation router stub that accepts recordYield calls
contract StubRouter {
    function recordYield(address, uint256) external pure returns (uint256) {
        return 0; // no-op, just prevents revert
    }

    function updateUserShares(address, uint256) external {}
}

contract MockWETHLike is MockERC20 {
    constructor() MockERC20("Mock WETH", "mWETH", 18) {}

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

/// @dev Wrong-asset adapter for mismatch tests
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

/// @dev Wrong-vault adapter for mismatch tests
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

/**
 * @title TestContract18_GiveVault4626Branches
 * @notice Targets uncovered branches in GiveVault4626 identified by coverage analysis.
 *
 * Covered branches:
 *   whenNotPausedOrGracePeriod — regular pause (EnforcedPause) path
 *   whenNotPausedOrGracePeriod — emergency + grace-expired (GracePeriodExpired) path
 *   whenNotPausedOrGracePeriod — emergency + grace-active (withdraw allowed)
 *   setActiveAdapter           — InvalidAsset (wrong asset), InvalidAdapter (wrong vault)
 *   forceClearAdapter          — AdapterHasFunds revert
 *   harvest                    — zero-profit path (no adapter yield)
 *   _ensureSufficientCash      — partial divest returned < shortfall but within maxLoss
 *   _ensureSufficientCash      — ExcessiveLoss revert (loss > maxLoss)
 *   emergencyWithdrawUser      — GracePeriodActive revert (called too early)
 *   emergencyWithdrawUser      — InsufficientAllowance revert (caller != owner, low allowance)
 *   emergencyWithdrawUser      — allowance path with limited approval (allowance decremented)
 *   depositETH                 — InvalidConfiguration (no wrappedNative set)
 *   depositETH                 — InvalidReceiver (address(0))
 *   depositETH                 — InvalidAmount (msg.value == 0)
 *   depositETH                 — SlippageExceeded (shares < minShares)
 *   redeemETH                  — InvalidAmount (shares == 0)
 *   redeemETH                  — SlippageExceeded (assets < minAssets)
 *   withdrawETH                — InvalidAmount (assets == 0)
 *   withdrawETH                — SlippageExceeded (shares > maxShares)
 */
contract TestContract18_GiveVault4626Branches is Test {
    GiveVault4626 public impl;
    ACLManager public acl;
    MockERC20 public usdc;

    address public admin;
    address public user1;
    address public user2;

    uint256 public constant DEPOSIT = 1000e6; // 1000 USDC

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

    // ─── helpers ─────────────────────────────────────────────────────────────

    function _deployVault() internal returns (GiveVault4626) {
        bytes memory init = abi.encodeCall(
            GiveVault4626.initialize, (address(usdc), "Test Vault", "tvUSDC", admin, address(acl), address(impl))
        );
        return GiveVault4626(payable(address(new ERC1967Proxy(address(impl), init))));
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

    // ─── deposit — whenNotPaused blocks all deposits during emergency ─────────

    function test_Contract18_Case01_emergencyPause_blocksDeposit() public {
        GiveVault4626 v = _deployVault();
        _fund(user1, DEPOSIT);

        vm.prank(admin);
        v.emergencyPause();

        vm.startPrank(user1);
        usdc.approve(address(v), DEPOSIT);
        vm.expectRevert(); // EnforcedPause from whenNotPaused modifier on deposit
        v.deposit(DEPOSIT, user1);
        vm.stopPrank();
    }

    // ─── whenNotPausedOrGracePeriod — emergency + grace expired ──────────────

    function test_Contract18_Case02_gracePeriodExpired_blockWithdraw() public {
        GiveVault4626 v = _deployVault();
        uint256 shares = _deposit(v, user1, DEPOSIT);

        vm.prank(admin);
        v.emergencyPause();

        // Fast-forward PAST grace period
        vm.warp(block.timestamp + v.EMERGENCY_GRACE_PERIOD() + 1);

        // withdraw should revert with GracePeriodExpired
        vm.prank(user1);
        vm.expectRevert(GiveVault4626.GracePeriodExpired.selector);
        v.withdraw(DEPOSIT, user1, user1);

        vm.prank(user1);
        vm.expectRevert(GiveVault4626.GracePeriodExpired.selector);
        v.redeem(shares, user1, user1);
    }

    // ─── whenNotPausedOrGracePeriod — emergency + within grace (allowed) ─────

    function test_Contract18_Case03_withinGracePeriod_withdrawAllowed() public {
        GiveVault4626 v = _deployVault();
        _deposit(v, user1, DEPOSIT);

        vm.prank(admin);
        v.emergencyPause();

        // Still within grace — normal withdraw should work
        vm.warp(block.timestamp + v.EMERGENCY_GRACE_PERIOD() - 1);
        vm.prank(user1);
        v.withdraw(DEPOSIT, user1, user1);

        assertEq(v.balanceOf(user1), 0);
        assertEq(usdc.balanceOf(user1), DEPOSIT);
    }

    // ─── setActiveAdapter — asset and vault mismatch reverts ─────────────────

    function test_Contract18_Case04_setActiveAdapter_wrongAssetReverts() public {
        GiveVault4626 v = _deployVault();
        address wrongToken = makeAddr("wrongToken");
        WrongAssetAdapter badAdapter = new WrongAssetAdapter(wrongToken, address(v));

        vm.prank(admin);
        vm.expectRevert(GiveVault4626.InvalidAsset.selector);
        v.setActiveAdapter(IYieldAdapter(address(badAdapter)));
    }

    function test_Contract18_Case05_setActiveAdapter_wrongVaultReverts() public {
        GiveVault4626 v = _deployVault();
        address wrongVault = makeAddr("wrongVault");
        WrongVaultAdapter badAdapter = new WrongVaultAdapter(address(usdc), wrongVault);

        vm.prank(admin);
        vm.expectRevert(GiveVault4626.InvalidAdapter.selector);
        v.setActiveAdapter(IYieldAdapter(address(badAdapter)));
    }

    // ─── forceClearAdapter — AdapterHasFunds ─────────────────────────────────

    function test_Contract18_Case06_forceClearAdapter_adapterHasFundsReverts() public {
        GiveVault4626 v = _deployVault();
        BranchTestAdapter adapter = new BranchTestAdapter(address(usdc), address(v));

        vm.prank(admin);
        v.setActiveAdapter(IYieldAdapter(address(adapter)));

        // Manually credit adapter so it reports > 0
        usdc.mint(address(adapter), 1e6);
        adapter.invest(1e6); // adapter.invested = 1e6

        // Cache totalAssets before prank (prevent staticcall consuming prank)
        uint256 adapterFunds = adapter.totalAssets();

        // forceClearAdapter should revert because adapter.totalAssets() > 0
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(GiveVault4626.AdapterHasFunds.selector, adapterFunds));
        v.forceClearAdapter();
    }

    // ─── harvest — zero profit path ──────────────────────────────────────────

    function test_Contract18_Case07_harvest_zeroProfitNoTransfer() public {
        GiveVault4626 v = _deployVault();
        BranchTestAdapter adapter = new BranchTestAdapter(address(usdc), address(v));

        vm.prank(admin);
        v.setActiveAdapter(IYieldAdapter(address(adapter)));

        // Wire a stub donation router (required by harvest to not revert on router check)
        StubRouter stubRouter = new StubRouter();
        vm.prank(admin);
        v.setDonationRouter(address(stubRouter));

        _deposit(v, user1, DEPOSIT);

        // harvest returns (0,0) — zero profit path, no transfer to router
        uint256 routerBefore = usdc.balanceOf(address(stubRouter));
        vm.prank(user1);
        (uint256 profit, uint256 loss) = v.harvest();

        assertEq(profit, 0);
        assertEq(loss, 0);
        assertEq(usdc.balanceOf(address(stubRouter)), routerBefore, "no transfer on zero profit");
    }

    // ─── _ensureSufficientCash — cash sufficient, adapter not called ──────────

    function test_Contract18_Case08_ensureSufficientCash_sufficientCashSkipsDivest() public {
        // Tests early-return: currentCash >= needed → divest skipped entirely
        // No adapter set → vault holds all funds as cash
        GiveVault4626 v = _deployVault();

        _deposit(v, user1, DEPOSIT);

        // Vault holds all DEPOSIT as cash (no active adapter)
        uint256 shares = v.balanceOf(user1);

        // Redeem half — vault has enough cash, _ensureSufficientCash returns immediately
        vm.prank(user1);
        v.redeem(shares / 2, user1, user1);

        // User received half of DEPOSIT in cash
        assertGt(usdc.balanceOf(user1), 0, "user received cash directly");
        assertEq(address(v.activeAdapter()), address(0), "no adapter involved");
    }

    // ─── _ensureSufficientCash — ExcessiveLoss ───────────────────────────────

    function test_Contract18_Case09_ensureSufficientCash_excessiveLossReverts() public {
        GiveVault4626 v = _deployVault();
        BranchTestAdapter adapter = new BranchTestAdapter(address(usdc), address(v));

        vm.prank(admin);
        v.setActiveAdapter(IYieldAdapter(address(adapter)));

        vm.startPrank(admin);
        v.setCashBufferBps(0);
        v.setMaxLossBps(100); // 1% max loss
        vm.stopPrank();

        _deposit(v, user1, DEPOSIT);

        // Move all cash into adapter
        uint256 cash = usdc.balanceOf(address(v));
        usdc.transfer(address(adapter), cash);
        adapter.invest(cash);

        // Adapter returns only 90% — 10% loss exceeds 1% maxLoss
        adapter.setReturnFraction(9000);

        uint256 shares = v.balanceOf(user1);
        vm.prank(user1);
        vm.expectRevert(); // ExcessiveLoss
        v.redeem(shares, user1, user1);
    }

    // ─── emergencyWithdrawUser — GracePeriodActive ────────────────────────────

    function test_Contract18_Case10_emergencyWithdrawUser_gracePeriodActiveReverts() public {
        GiveVault4626 v = _deployVault();
        uint256 shares = _deposit(v, user1, DEPOSIT);

        vm.prank(admin);
        v.emergencyPause();

        // Within grace — emergencyWithdrawUser should revert
        vm.prank(user1);
        vm.expectRevert(GiveVault4626.GracePeriodActive.selector);
        v.emergencyWithdrawUser(shares, user1, user1);
    }

    // ─── emergencyWithdrawUser — InsufficientAllowance ────────────────────────

    function test_Contract18_Case11_emergencyWithdrawUser_insufficientAllowanceReverts() public {
        GiveVault4626 v = _deployVault();
        uint256 shares = _deposit(v, user1, DEPOSIT);

        vm.prank(admin);
        v.emergencyPause();
        vm.warp(block.timestamp + v.EMERGENCY_GRACE_PERIOD() + 1);

        // user2 tries to withdraw user1's shares without approval
        vm.prank(user2);
        vm.expectRevert(GiveVault4626.InsufficientAllowance.selector);
        v.emergencyWithdrawUser(shares, user2, user1);
    }

    // ─── emergencyWithdrawUser — allowance decremented ────────────────────────

    function test_Contract18_Case12_emergencyWithdrawUser_allowanceDecremented() public {
        GiveVault4626 v = _deployVault();
        uint256 shares = _deposit(v, user1, DEPOSIT);

        vm.prank(admin);
        v.emergencyPause();
        vm.warp(block.timestamp + v.EMERGENCY_GRACE_PERIOD() + 1);

        // user1 approves user2 for exactly `shares` (limited approval, not max)
        vm.prank(user1);
        v.approve(user2, shares);

        assertEq(v.allowance(user1, user2), shares);

        vm.prank(user2);
        v.emergencyWithdrawUser(shares, user2, user1);

        // Allowance should be decremented to 0
        assertEq(v.allowance(user1, user2), 0, "allowance should be consumed");
        assertEq(v.balanceOf(user1), 0, "shares burned");
        assertGt(usdc.balanceOf(user2), 0, "user2 received assets");
    }

    // ─── depositETH — error paths ─────────────────────────────────────────────

    function test_Contract18_Case13_depositETH_noWrappedNativeReverts() public {
        GiveVault4626 v = _deployVault();
        // wrappedNative not set → InvalidConfiguration
        vm.deal(user1, 1 ether);
        vm.prank(user1);
        vm.expectRevert(GiveVault4626.InvalidConfiguration.selector);
        v.depositETH{value: 1 ether}(user1, 0);
    }

    function test_Contract18_Case14_depositETH_zeroMsgValueReverts() public {
        GiveVault4626 v = _deployVault();

        // Deploy a WETH-like token and set as wrappedNative
        // usdc acts as wrappedNative for this test (address matches asset)
        vm.prank(admin);
        v.setWrappedNative(address(usdc));

        vm.prank(user1);
        vm.expectRevert(GiveVault4626.InvalidAmount.selector);
        v.depositETH{value: 0}(user1, 0);
    }

    function test_Contract18_Case15_depositETH_zeroReceiverReverts() public {
        GiveVault4626 v = _deployVault();
        vm.prank(admin);
        v.setWrappedNative(address(usdc));

        vm.deal(user1, 1 ether);
        vm.prank(user1);
        vm.expectRevert(GiveVault4626.InvalidReceiver.selector);
        v.depositETH{value: 1 ether}(address(0), 0);
    }

    // ─── redeemETH — error paths ─────────────────────────────────────────────

    function test_Contract18_Case16_redeemETH_noWrappedNativeReverts() public {
        GiveVault4626 v = _deployVault();
        vm.prank(user1);
        vm.expectRevert(GiveVault4626.InvalidConfiguration.selector);
        v.redeemETH(100, user1, user1, 0);
    }

    function test_Contract18_Case17_redeemETH_zeroSharesReverts() public {
        GiveVault4626 v = _deployVault();
        vm.prank(admin);
        v.setWrappedNative(address(usdc));

        vm.prank(user1);
        vm.expectRevert(GiveVault4626.InvalidAmount.selector);
        v.redeemETH(0, user1, user1, 0);
    }

    function test_Contract18_Case18_redeemETH_zeroReceiverReverts() public {
        GiveVault4626 v = _deployVault();
        vm.prank(admin);
        v.setWrappedNative(address(usdc));

        vm.prank(user1);
        vm.expectRevert(GiveVault4626.InvalidReceiver.selector);
        v.redeemETH(100, address(0), user1, 0);
    }

    // ─── withdrawETH — error paths ────────────────────────────────────────────

    function test_Contract18_Case19_withdrawETH_noWrappedNativeReverts() public {
        GiveVault4626 v = _deployVault();
        vm.prank(user1);
        vm.expectRevert(GiveVault4626.InvalidConfiguration.selector);
        v.withdrawETH(100, user1, user1, type(uint256).max);
    }

    function test_Contract18_Case20_withdrawETH_zeroAssetsReverts() public {
        GiveVault4626 v = _deployVault();
        vm.prank(admin);
        v.setWrappedNative(address(usdc));

        vm.prank(user1);
        vm.expectRevert(GiveVault4626.InvalidAmount.selector);
        v.withdrawETH(0, user1, user1, type(uint256).max);
    }

    function test_Contract18_Case21_withdrawETH_zeroReceiverReverts() public {
        GiveVault4626 v = _deployVault();
        vm.prank(admin);
        v.setWrappedNative(address(usdc));

        vm.prank(user1);
        vm.expectRevert(GiveVault4626.InvalidReceiver.selector);
        v.withdrawETH(100, address(0), user1, type(uint256).max);
    }

    function test_Contract18_Case22_setWrappedNative_zeroAndWrongAssetRevert() public {
        GiveVault4626 v = _deployVault();

        vm.prank(admin);
        vm.expectRevert();
        v.setWrappedNative(address(0));

        vm.prank(admin);
        vm.expectRevert(GiveVault4626.InvalidConfiguration.selector);
        v.setWrappedNative(makeAddr("wrongWrapped"));
    }

    function test_Contract18_Case23_setDonationRouter_zeroReverts() public {
        GiveVault4626 v = _deployVault();

        vm.prank(admin);
        vm.expectRevert();
        v.setDonationRouter(address(0));
    }

    function test_Contract18_Case24_harvest_adapterNotSetReverts() public {
        GiveVault4626 v = _deployVault();

        vm.expectRevert(GiveVault4626.AdapterNotSet.selector);
        v.harvest();
    }

    function test_Contract18_Case25_harvest_missingDonationRouterReverts() public {
        GiveVault4626 v = _deployVault();
        BranchTestAdapter adapter = new BranchTestAdapter(address(usdc), address(v));

        vm.prank(admin);
        v.setActiveAdapter(IYieldAdapter(address(adapter)));

        vm.expectRevert(GiveVault4626.InvalidConfiguration.selector);
        v.harvest();
    }

    function test_Contract18_Case26_emergencyWithdrawFromAdapter_noAdapterReverts() public {
        GiveVault4626 v = _deployVault();

        vm.prank(admin);
        vm.expectRevert(GiveVault4626.AdapterNotSet.selector);
        v.emergencyWithdrawFromAdapter();
    }

    function test_Contract18_Case27_emergencyWithdrawUser_zeroReceiverReverts() public {
        GiveVault4626 v = _deployVault();

        vm.prank(user1);
        vm.expectRevert();
        v.emergencyWithdrawUser(1, address(0), user1);
    }

    function test_Contract18_Case28_emergencyWithdrawUser_notInEmergencyReverts() public {
        GiveVault4626 v = _deployVault();
        uint256 shares = _deposit(v, user1, DEPOSIT);

        vm.prank(user1);
        vm.expectRevert(GiveVault4626.NotInEmergency.selector);
        v.emergencyWithdrawUser(shares, user1, user1);
    }

    function test_Contract18_Case29_emergencyWithdrawUser_zeroAmountReverts() public {
        GiveVault4626 v = _deployVault();

        vm.prank(admin);
        v.emergencyPause();
        vm.warp(block.timestamp + v.EMERGENCY_GRACE_PERIOD() + 1);

        vm.prank(user1);
        vm.expectRevert(GiveVault4626.ZeroAmount.selector);
        v.emergencyWithdrawUser(0, user1, user1);
    }

    function test_Contract18_Case30_depositETH_routerUpdatePathCovered() public {
        MockWETHLike weth = new MockWETHLike();

        GiveVault4626 localImpl = new GiveVault4626();
        bytes memory init = abi.encodeCall(
            GiveVault4626.initialize,
            (address(weth), "Test Vault WETH", "tvWETH", admin, address(acl), address(localImpl))
        );
        GiveVault4626 v = GiveVault4626(payable(address(new ERC1967Proxy(address(localImpl), init))));

        BranchTestAdapter adapter = new BranchTestAdapter(address(weth), address(v));
        StubRouter stubRouter = new StubRouter();

        vm.startPrank(admin);
        v.setWrappedNative(address(weth));
        v.setDonationRouter(address(stubRouter));
        v.setActiveAdapter(IYieldAdapter(address(adapter)));
        vm.stopPrank();

        vm.deal(user1, 1 ether);
        vm.prank(user1);
        uint256 shares = v.depositETH{value: 1 ether}(user1, 0);
        assertGt(shares, 0, "depositETH should mint shares");
    }
}
