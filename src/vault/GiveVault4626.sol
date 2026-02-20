// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC4626Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/math/SafeCast.sol";

import "../interfaces/IYieldAdapter.sol";
import "../interfaces/IWETH.sol";
import "../payout/PayoutRouter.sol";
import "../modules/RiskModule.sol";
import "../types/GiveTypes.sol";
import "./VaultTokenBase.sol";

/**
 * @title GiveVault4626
 * @author GIVE Labs
 * @notice UUPS-upgradeable ERC-4626 vault for no-loss giving with yield generation
 * @dev Core vault implementation managing deposits, withdrawals, yield harvesting, and donations.
 *      Critical fixes for C-01 and M-01: Uses UUPS proxies instead of EIP-1167 clones.
 *
 *      Key Features:
 *      - ERC-4626 compliant tokenized vault
 *      - Yield generation via pluggable adapters
 *      - Automated donation distribution from harvested yield
 *      - Emergency pause and graceful shutdown
 *      - Cash buffer management for withdrawal liquidity
 *      - Risk limit enforcement
 *      - Native ETH convenience methods (wrap/unwrap)
 *      - UUPS upgradeability (M-01 fix)
 *
 *      Architecture Changes from v0.5:
 *      - ❌ REMOVED: Constructor-based initialization
 *      - ✅ ADDED: initialize() for UUPS proxy pattern
 *      - ✅ ADDED: _authorizeUpgrade for controlled upgrades
 *      - ✅ FIXED: Emergency withdrawal now requires owner authorization
 *
 *      C-01 & M-01 Fix:
 *      In v0.5, vaults were deployed as EIP-1167 clones which:
 *      1. Shared immutable _vaultId causing storage collision (C-01)
 *      2. Could not be upgraded (M-01)
 *      Now each vault is a UUPS proxy with unique storage and upgrade capability.
 *
 *      Emergency System:
 *      - emergencyPause(): Pauses vault, withdraws from adapter, starts grace period
 *      - Grace period (24 hours): Normal withdrawals still work
 *      - After grace: Must use emergencyWithdrawUser() with owner auth
 *      - resumeFromEmergency(): Restores normal operations
 *
 *      Security Model:
 *      - VAULT_MANAGER_ROLE: Configure vault parameters, adapters, risk limits
 *      - PAUSER_ROLE: Emergency pause/unpause
 *      - DEFAULT_ADMIN_ROLE: Emergency adapter withdrawal, upgrades
 *      - ROLE_UPGRADER: Contract upgrades via UUPS
 */
contract GiveVault4626 is ERC4626Upgradeable, UUPSUpgradeable, VaultTokenBase {
    using SafeERC20 for IERC20;

    // ============================================
    // CONSTANTS
    // ============================================

    /// @notice Role for vault configuration and management
    bytes32 public constant VAULT_MANAGER_ROLE = keccak256("VAULT_MANAGER_ROLE");

    /// @notice Role for emergency pause operations
    bytes32 public constant PAUSER_ROLE = keccak256("PAUSER_ROLE");

    /// @notice Role for contract upgrades
    bytes32 public constant ROLE_UPGRADER = keccak256("ROLE_UPGRADER");

    /// @notice Basis points denominator (100% = 10000)
    uint256 public constant BASIS_POINTS = 10000;

    /// @notice Maximum cash buffer (20%)
    uint256 public constant MAX_CASH_BUFFER_BPS = 2000;

    /// @notice Maximum slippage tolerance (10%)
    uint256 public constant MAX_SLIPPAGE_BPS = 1000;

    /// @notice Maximum acceptable loss (5%)
    uint256 public constant MAX_LOSS_BPS = 500;

    /// @notice Grace period after emergency pause before emergency withdrawal required (24 hours)
    uint256 public constant EMERGENCY_GRACE_PERIOD = 24 hours;

    // ============================================
    // EVENTS
    // ============================================

    event AdapterUpdated(address indexed oldAdapter, address indexed newAdapter);
    event CashBufferUpdated(uint256 oldBps, uint256 newBps);
    event SlippageUpdated(uint256 oldBps, uint256 newBps);
    event MaxLossUpdated(uint256 oldBps, uint256 newBps);
    event PayoutRouterUpdated(address indexed oldRouter, address indexed newRouter);
    event Harvest(uint256 profit, uint256 loss, uint256 donated);
    event InvestPausedToggled(bool paused);
    event HarvestPausedToggled(bool paused);
    event EmergencyWithdraw(uint256 amount);
    event WrappedNativeSet(address indexed token);
    event RiskLimitsUpdated(bytes32 indexed riskId, uint256 maxDeposit, uint256 maxBorrow);
    event EmergencyWithdrawal(address indexed owner, address indexed receiver, uint256 shares, uint256 assets);

    // ============================================
    // ERRORS
    // ============================================

    error InvalidConfiguration();
    error InvestPaused();
    error HarvestPaused();
    error GracePeriodExpired();
    error InvalidAsset();
    error InvalidAdapter();
    error InsufficientCash();
    error AdapterNotSet();
    error ExcessiveLoss(uint256 loss, uint256 maxLoss);
    error CashBufferTooHigh();
    error InvalidSlippageBps();
    error InvalidMaxLossBps();
    error NotInEmergency();
    error GracePeriodActive();
    error InsufficientAllowance();
    error ZeroAmount();
    error InvalidReceiver();
    error InvalidAmount();
    error SlippageExceeded(uint256 expected, uint256 actual);
    error TransferFailed();
    error AdapterHasFunds(uint256 remaining);
    error Unauthorized(bytes32 roleId, address account);

    // ============================================
    // MODIFIERS
    // ============================================

    modifier whenInvestNotPaused() {
        if (_vaultConfig().investPaused) revert InvestPaused();
        _;
    }

    modifier whenHarvestNotPaused() {
        if (_vaultConfig().harvestPaused) revert HarvestPaused();
        _;
    }

    modifier whenNotPausedOrGracePeriod() {
        if (paused()) {
            GiveTypes.VaultConfig storage cfg = _vaultConfig();
            if (cfg.emergencyShutdown) {
                if (block.timestamp >= cfg.emergencyActivatedAt + EMERGENCY_GRACE_PERIOD) {
                    revert GracePeriodExpired();
                }
            } else {
                revert EnforcedPause();
            }
        }
        _;
    }

    // ============================================
    // INITIALIZATION
    // ============================================

    /**
     * @notice Initializes the vault
     * @dev Replaces constructor for UUPS proxy pattern.
     *      Sets unique vaultId, configures ERC4626/ERC20, grants roles, initializes config.
     *      Can only be called once per proxy due to initializer modifier.
     * @param asset_ Underlying ERC20 asset (e.g., USDC, WETH)
     * @param name_ ERC20 token name for vault shares
     * @param symbol_ ERC20 token symbol for vault shares
     * @param admin_ Admin address to receive DEFAULT_ADMIN_ROLE
     * @param acl_ ACL manager address for role checks
     * @param implementation_ Address of the vault implementation contract
     */
    function initialize(
        address asset_,
        string memory name_,
        string memory symbol_,
        address admin_,
        address acl_,
        address implementation_
    ) public virtual initializer {
        if (admin_ == address(0) || acl_ == address(0) || implementation_ == address(0)) {
            revert ZeroAddress();
        }

        _initParents(asset_, name_, symbol_, acl_);
        _initRolesAndConfig(admin_, implementation_, asset_);
    }

    /// @dev Calls parent initializers in a separate frame to reduce stack depth in initialize()
    function _initParents(address asset_, string memory name_, string memory symbol_, address acl_) private {
        __ERC4626_init(IERC20(asset_));
        __ERC20_init(name_, symbol_);
        __VaultTokenBase_init(acl_);
        __UUPSUpgradeable_init();
    }

    /// @dev Grants roles and writes initial config in a separate frame to reduce stack depth in initialize()
    function _initRolesAndConfig(address admin_, address implementation_, address asset_) private {
        _grantRole(DEFAULT_ADMIN_ROLE, admin_);
        _grantRole(VAULT_MANAGER_ROLE, admin_);
        _grantRole(PAUSER_ROLE, admin_);

        GiveTypes.VaultConfig storage cfg = _vaultConfig();
        cfg.id = vaultId();
        cfg.proxy = address(this);
        cfg.implementation = implementation_;
        cfg.asset = asset_;
        cfg.cashBufferBps = 100; // 1% default
        cfg.slippageBps = 50; // 0.5% default
        cfg.maxLossBps = 50; // 0.5% default
        cfg.lastHarvestTime = block.timestamp;
        cfg.active = true;
    }

    /**
     * @notice Receive function for unwrapping WETH
     * @dev Only accepts ETH from configured wrapped native token
     */
    receive() external payable {
        GiveTypes.VaultConfig storage cfg = _vaultConfig();
        if (cfg.wrappedNative == address(0) || msg.sender != cfg.wrappedNative) {
            revert InvalidConfiguration();
        }
    }

    // ============================================
    // ERC4626 OVERRIDES
    // ============================================

    function totalAssets() public view override returns (uint256) {
        GiveTypes.VaultConfig storage cfg = _vaultConfig();
        uint256 cash = IERC20(asset()).balanceOf(address(this));
        uint256 adapterAssets = cfg.activeAdapter != address(0) ? IYieldAdapter(cfg.activeAdapter).totalAssets() : 0;
        return cash + adapterAssets;
    }

    function deposit(uint256 assets, address receiver) public override nonReentrant whenNotPaused returns (uint256) {
        return super.deposit(assets, receiver);
    }

    function mint(uint256 shares, address receiver) public override nonReentrant whenNotPaused returns (uint256) {
        return super.mint(shares, receiver);
    }

    function withdraw(uint256 assets, address receiver, address owner)
        public
        override
        nonReentrant
        whenNotPausedOrGracePeriod
        returns (uint256)
    {
        return super.withdraw(assets, receiver, owner);
    }

    function redeem(uint256 shares, address receiver, address owner)
        public
        override
        nonReentrant
        whenNotPausedOrGracePeriod
        returns (uint256)
    {
        return super.redeem(shares, receiver, owner);
    }

    function _deposit(address caller, address receiver, uint256 assets, uint256 shares)
        internal
        override
        whenNotPaused
    {
        RiskModule.enforceDepositLimit(vaultId(), totalAssets(), assets);
        super._deposit(caller, receiver, assets, shares);

        address router = _vaultConfig().donationRouter;
        if (router != address(0)) {
            PayoutRouter(payable(router)).updateUserShares(receiver, balanceOf(receiver));
        }

        _investExcessCash();
    }

    function _withdraw(address caller, address receiver, address owner, uint256 assets, uint256 shares)
        internal
        override
        whenNotPausedOrGracePeriod
    {
        _ensureSufficientCash(assets);
        super._withdraw(caller, receiver, owner, assets, shares);

        address router = _vaultConfig().donationRouter;
        if (router != address(0)) {
            PayoutRouter(payable(router)).updateUserShares(owner, balanceOf(owner));
        }
    }

    // ============================================
    // VAULT MANAGEMENT
    // ============================================

    function setWrappedNative(address wrapped) external onlyRole(VAULT_MANAGER_ROLE) {
        if (wrapped == address(0)) revert ZeroAddress();
        if (wrapped != address(asset())) revert InvalidConfiguration();
        _vaultConfig().wrappedNative = wrapped;
        emit WrappedNativeSet(wrapped);
    }

    function setActiveAdapter(IYieldAdapter adapter) external onlyRole(VAULT_MANAGER_ROLE) whenNotPaused {
        GiveTypes.VaultConfig storage cfg = _vaultConfig();
        address adapterAddr = address(adapter);
        if (adapterAddr != address(0)) {
            if (adapter.asset() != IERC20(asset())) revert InvalidAsset();
            if (adapter.vault() != address(this)) revert InvalidAdapter();
        }

        address oldAdapter = cfg.activeAdapter;
        cfg.activeAdapter = adapterAddr;
        cfg.adapterId = adapterAddr == address(0) ? bytes32(0) : bytes32(uint256(uint160(adapterAddr)));

        emit AdapterUpdated(oldAdapter, adapterAddr);
    }

    function forceClearAdapter() external onlyRole(VAULT_MANAGER_ROLE) {
        GiveTypes.VaultConfig storage cfg = _vaultConfig();
        address oldAdapter = cfg.activeAdapter;
        if (oldAdapter != address(0)) {
            uint256 remaining = IYieldAdapter(oldAdapter).totalAssets();
            if (remaining != 0) revert AdapterHasFunds(remaining);
        }
        cfg.activeAdapter = address(0);
        cfg.adapterId = bytes32(0);
        emit AdapterUpdated(oldAdapter, address(0));
    }

    function setDonationRouter(address router) external onlyRole(VAULT_MANAGER_ROLE) {
        if (router == address(0)) revert ZeroAddress();
        GiveTypes.VaultConfig storage cfg = _vaultConfig();
        address oldRouter = cfg.donationRouter;
        cfg.donationRouter = router;
        emit PayoutRouterUpdated(oldRouter, router);
    }

    function setCashBufferBps(uint256 bps) external onlyRole(VAULT_MANAGER_ROLE) {
        if (bps > MAX_CASH_BUFFER_BPS) revert CashBufferTooHigh();
        GiveTypes.VaultConfig storage cfg = _vaultConfig();
        uint256 old = cfg.cashBufferBps;
        cfg.cashBufferBps = SafeCast.toUint16(bps);
        emit CashBufferUpdated(old, bps);
    }

    function setSlippageBps(uint256 bps) external onlyRole(VAULT_MANAGER_ROLE) {
        if (bps > MAX_SLIPPAGE_BPS) revert InvalidSlippageBps();
        GiveTypes.VaultConfig storage cfg = _vaultConfig();
        uint256 old = cfg.slippageBps;
        cfg.slippageBps = SafeCast.toUint16(bps);
        emit SlippageUpdated(old, bps);
    }

    function setMaxLossBps(uint256 bps) external onlyRole(VAULT_MANAGER_ROLE) {
        if (bps > MAX_LOSS_BPS) revert InvalidMaxLossBps();
        GiveTypes.VaultConfig storage cfg = _vaultConfig();
        uint256 old = cfg.maxLossBps;
        cfg.maxLossBps = SafeCast.toUint16(bps);
        emit MaxLossUpdated(old, bps);
    }

    function setInvestPaused(bool paused_) external onlyRole(PAUSER_ROLE) {
        GiveTypes.VaultConfig storage cfg = _vaultConfig();
        cfg.investPaused = paused_;
        emit InvestPausedToggled(paused_);
    }

    function setHarvestPaused(bool paused_) external onlyRole(PAUSER_ROLE) {
        GiveTypes.VaultConfig storage cfg = _vaultConfig();
        cfg.harvestPaused = paused_;
        emit HarvestPausedToggled(paused_);
    }

    function syncRiskLimits(bytes32 riskId, uint256 maxDeposit, uint256 maxBorrow)
        external
        onlyRole(VAULT_MANAGER_ROLE)
    {
        GiveTypes.VaultConfig storage cfg = _vaultConfig();
        cfg.riskId = riskId;
        cfg.maxVaultDeposit = maxDeposit;
        cfg.maxVaultBorrow = maxBorrow;
        emit RiskLimitsUpdated(riskId, maxDeposit, maxBorrow);
    }

    function emergencyPause() external onlyRole(PAUSER_ROLE) {
        GiveTypes.VaultConfig storage cfg = _vaultConfig();
        _pause();
        cfg.investPaused = true;
        cfg.harvestPaused = true;
        cfg.emergencyShutdown = true;
        cfg.emergencyActivatedAt = uint64(block.timestamp);

        address adapterAddr = cfg.activeAdapter;
        if (adapterAddr != address(0)) {
            try IYieldAdapter(adapterAddr).emergencyWithdraw() returns (uint256 withdrawn) {
                emit EmergencyWithdraw(withdrawn);
            } catch {}
        }

        emit InvestPausedToggled(true);
        emit HarvestPausedToggled(true);
    }

    function resumeFromEmergency() external onlyRole(PAUSER_ROLE) {
        GiveTypes.VaultConfig storage cfg = _vaultConfig();
        _unpause();
        cfg.investPaused = false;
        cfg.harvestPaused = false;
        cfg.emergencyShutdown = false;
        cfg.emergencyActivatedAt = 0;
        emit InvestPausedToggled(false);
        emit HarvestPausedToggled(false);
    }

    // ============================================
    // YIELD OPERATIONS
    // ============================================

    function harvest() external nonReentrant whenHarvestNotPaused returns (uint256 profit, uint256 loss) {
        GiveTypes.VaultConfig storage cfg = _vaultConfig();
        address adapterAddr = cfg.activeAdapter;
        if (adapterAddr == address(0)) revert AdapterNotSet();
        if (cfg.donationRouter == address(0)) revert InvalidConfiguration();

        (profit, loss) = IYieldAdapter(adapterAddr).harvest();

        cfg.totalProfit += profit;
        cfg.totalLoss += loss;
        cfg.lastHarvestTime = block.timestamp;

        uint256 donated = 0;
        if (profit > 0) {
            IERC20(asset()).safeTransfer(cfg.donationRouter, profit);
            donated = PayoutRouter(payable(cfg.donationRouter)).recordYield(asset(), profit);
        }

        emit Harvest(profit, loss, donated);
    }

    function emergencyWithdrawFromAdapter() external onlyRole(DEFAULT_ADMIN_ROLE) returns (uint256 withdrawn) {
        GiveTypes.VaultConfig storage cfg = _vaultConfig();
        address adapterAddr = cfg.activeAdapter;
        if (adapterAddr == address(0)) revert AdapterNotSet();

        withdrawn = IYieldAdapter(adapterAddr).emergencyWithdraw();
        emit EmergencyWithdraw(withdrawn);
    }

    /**
     * @notice Emergency withdrawal with owner authorization
     * @dev AUDIT FIX: Restores authorization check (v0.5 bypassed this).
     *      Only works during emergency shutdown, after grace period.
     *      Requires caller to be owner or have sufficient allowance.
     * @param shares Amount of shares to burn
     * @param receiver Address receiving withdrawn assets
     * @param owner Address owning the shares
     * @return assets Amount of assets withdrawn
     */
    function emergencyWithdrawUser(uint256 shares, address receiver, address owner)
        external
        nonReentrant
        returns (uint256 assets)
    {
        if (receiver == address(0)) revert ZeroAddress();

        GiveTypes.VaultConfig storage cfg = _vaultConfig();

        if (!cfg.emergencyShutdown) revert NotInEmergency();
        if (block.timestamp < cfg.emergencyActivatedAt + EMERGENCY_GRACE_PERIOD) {
            revert GracePeriodActive();
        }

        // AUDIT FIX: Restore authorization check
        if (msg.sender != owner) {
            uint256 allowed = allowance(owner, msg.sender);
            if (allowed < shares) revert InsufficientAllowance();
            if (allowed != type(uint256).max) {
                _approve(owner, msg.sender, allowed - shares);
            }
        }

        assets = previewRedeem(shares);
        if (assets == 0) revert ZeroAmount();

        _ensureSufficientCash(assets);
        _burn(owner, shares);
        IERC20(asset()).safeTransfer(receiver, assets);

        address router = cfg.donationRouter;
        if (router != address(0)) {
            try PayoutRouter(payable(router)).updateUserShares(owner, balanceOf(owner)) {} catch {}
        }

        emit EmergencyWithdrawal(owner, receiver, shares, assets);
    }

    // ============================================
    // INTERNAL FUNCTIONS
    // ============================================

    function _investExcessCash() internal {
        GiveTypes.VaultConfig storage cfg = _vaultConfig();
        if (cfg.investPaused) return;
        address adapterAddr = cfg.activeAdapter;
        if (adapterAddr == address(0)) return;

        uint256 totalCash = IERC20(asset()).balanceOf(address(this));
        uint256 targetCash = (totalAssets() * cfg.cashBufferBps) / BASIS_POINTS;

        if (totalCash > targetCash) {
            uint256 excessCash = totalCash - targetCash;
            IERC20(asset()).safeTransfer(adapterAddr, excessCash);
            IYieldAdapter(adapterAddr).invest(excessCash);
        }
    }

    function _ensureSufficientCash(uint256 needed) internal {
        GiveTypes.VaultConfig storage cfg = _vaultConfig();
        uint256 currentCash = IERC20(asset()).balanceOf(address(this));

        if (currentCash >= needed) return;

        address adapterAddr = cfg.activeAdapter;
        if (adapterAddr == address(0)) revert InsufficientCash();

        uint256 shortfall = needed - currentCash;
        uint256 returned = IYieldAdapter(adapterAddr).divest(shortfall);

        if (returned < shortfall) {
            uint256 loss = shortfall - returned;
            uint256 maxLoss = (shortfall * cfg.maxLossBps) / BASIS_POINTS;
            if (loss > maxLoss) revert ExcessiveLoss(loss, maxLoss);
        }
    }

    // ============================================
    // VIEW FUNCTIONS
    // ============================================

    function activeAdapter() public view returns (IYieldAdapter) {
        return IYieldAdapter(_vaultConfig().activeAdapter);
    }

    function donationRouter() public view returns (address) {
        return _vaultConfig().donationRouter;
    }

    function wrappedNative() public view returns (address) {
        return _vaultConfig().wrappedNative;
    }

    function cashBufferBps() public view returns (uint256) {
        return _vaultConfig().cashBufferBps;
    }

    function slippageBps() public view returns (uint256) {
        return _vaultConfig().slippageBps;
    }

    function maxLossBps() public view returns (uint256) {
        return _vaultConfig().maxLossBps;
    }

    function investPaused() public view returns (bool) {
        return _vaultConfig().investPaused;
    }

    function harvestPaused() public view returns (bool) {
        return _vaultConfig().harvestPaused;
    }

    function emergencyShutdown() public view returns (bool) {
        return _vaultConfig().emergencyShutdown;
    }

    function emergencyActivatedAt() public view returns (uint64) {
        return _vaultConfig().emergencyActivatedAt;
    }

    function lastHarvestTime() public view returns (uint256) {
        return _vaultConfig().lastHarvestTime;
    }

    function totalProfit() public view returns (uint256) {
        return _vaultConfig().totalProfit;
    }

    function totalLoss() public view returns (uint256) {
        return _vaultConfig().totalLoss;
    }

    function getCashBalance() external view returns (uint256) {
        return IERC20(asset()).balanceOf(address(this));
    }

    function getAdapterAssets() external view returns (uint256) {
        address adapterAddr = _vaultConfig().activeAdapter;
        return adapterAddr != address(0) ? IYieldAdapter(adapterAddr).totalAssets() : 0;
    }

    function getHarvestStats()
        external
        view
        returns (uint256 totalProfit_, uint256 totalLoss_, uint256 lastHarvestTime_)
    {
        GiveTypes.VaultConfig storage cfg = _vaultConfig();
        return (cfg.totalProfit, cfg.totalLoss, cfg.lastHarvestTime);
    }

    function getConfiguration()
        external
        view
        returns (
            uint256 cashBuffer,
            uint256 slippage,
            uint256 maxLoss,
            bool investPausedStatus,
            bool harvestPausedStatus
        )
    {
        GiveTypes.VaultConfig storage cfg = _vaultConfig();
        return (cfg.cashBufferBps, cfg.slippageBps, cfg.maxLossBps, cfg.investPaused, cfg.harvestPaused);
    }

    function emergencyShutdownActive() external view returns (bool) {
        return _vaultConfig().emergencyShutdown;
    }

    // ============================================
    // NATIVE ETH CONVENIENCE METHODS
    // ============================================

    function depositETH(address receiver, uint256 minShares)
        external
        payable
        nonReentrant
        whenNotPaused
        returns (uint256 shares)
    {
        GiveTypes.VaultConfig storage cfg = _vaultConfig();
        if (cfg.wrappedNative == address(0) || cfg.wrappedNative != address(asset())) {
            revert InvalidConfiguration();
        }
        if (receiver == address(0)) revert InvalidReceiver();
        if (msg.value == 0) revert InvalidAmount();

        RiskModule.enforceDepositLimit(vaultId(), totalAssets(), msg.value);
        shares = previewDeposit(msg.value);
        if (shares < minShares) revert SlippageExceeded(minShares, shares);

        IWETH(cfg.wrappedNative).deposit{value: msg.value}();
        _mint(receiver, shares);

        address router = cfg.donationRouter;
        if (router != address(0)) {
            PayoutRouter(payable(router)).updateUserShares(receiver, balanceOf(receiver));
        }

        _investExcessCash();

        emit Deposit(msg.sender, receiver, msg.value, shares);
        return shares;
    }

    function redeemETH(uint256 shares, address receiver, address owner, uint256 minAssets)
        external
        nonReentrant
        whenNotPaused
        returns (uint256 assets)
    {
        GiveTypes.VaultConfig storage cfg = _vaultConfig();
        if (cfg.wrappedNative == address(0) || cfg.wrappedNative != address(asset())) {
            revert InvalidConfiguration();
        }
        if (receiver == address(0)) revert InvalidReceiver();
        if (shares == 0) revert InvalidAmount();

        assets = previewRedeem(shares);
        if (assets < minAssets) revert SlippageExceeded(minAssets, assets);

        _withdraw(msg.sender, address(this), owner, assets, shares);

        IWETH(cfg.wrappedNative).withdraw(assets);
        (bool ok,) = payable(receiver).call{value: assets}("");
        if (!ok) revert TransferFailed();

        return assets;
    }

    function withdrawETH(uint256 assets, address receiver, address owner, uint256 maxShares)
        external
        nonReentrant
        whenNotPaused
        returns (uint256 shares)
    {
        GiveTypes.VaultConfig storage cfg = _vaultConfig();
        if (cfg.wrappedNative == address(0) || cfg.wrappedNative != address(asset())) {
            revert InvalidConfiguration();
        }
        if (receiver == address(0)) revert InvalidReceiver();
        if (assets == 0) revert InvalidAmount();

        shares = previewWithdraw(assets);
        if (shares > maxShares) revert SlippageExceeded(shares, maxShares);

        _withdraw(msg.sender, address(this), owner, assets, shares);

        IWETH(cfg.wrappedNative).withdraw(assets);
        (bool ok,) = payable(receiver).call{value: assets}("");
        if (!ok) revert TransferFailed();

        return shares;
    }

    // ============================================
    // UUPS UPGRADE AUTHORIZATION
    // ============================================

    /**
     * @notice UUPS upgrade authorization hook
     * @dev Only addresses with ROLE_UPGRADER can upgrade this vault.
     *      Each vault can be upgraded independently.
     * @param newImplementation Address of new implementation (unused but required by interface)
     */
    function _authorizeUpgrade(address newImplementation) internal view override {
        if (!aclManager.hasRole(ROLE_UPGRADER, msg.sender)) {
            revert Unauthorized(ROLE_UPGRADER, msg.sender);
        }
    }
}
