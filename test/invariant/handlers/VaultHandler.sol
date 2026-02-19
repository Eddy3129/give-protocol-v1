// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";

import {GiveVault4626} from "../../../src/vault/GiveVault4626.sol";
import {MockERC20} from "../../../src/mocks/MockERC20.sol";

// ─── Minimal mock ─────────────────────────────────────────────────────────────

contract VaultMockACL {
    function hasRole(bytes32, address) external pure returns (bool) {
        return false; // Vault falls back to local AccessControl roles
    }
}

// ─── Handler ──────────────────────────────────────────────────────────────────

/// @title VaultHandler
/// @notice Invariant handler for GiveVault4626 (no yield adapter — pure ERC4626 math).
///         Uses four actors. Ghost variables track net asset flows for invariant checks.
contract VaultHandler is Test {
    // ── Contract under test ──────────────────────────────────────────
    GiveVault4626 public immutable vault;
    MockERC20 public immutable asset;

    // ── Actors ───────────────────────────────────────────────────────
    uint256 public constant ACTOR_COUNT = 4;
    address[4] internal _actors;
    address internal immutable _admin;

    // ── Ghost variables ──────────────────────────────────────────────
    /// @notice Total assets deposited into the vault across all actors
    uint256 public ghost_totalDeposited;
    /// @notice Total assets withdrawn from the vault across all actors
    uint256 public ghost_totalWithdrawn;
    /// @notice Total synthetic yield injected directly to vault balance
    uint256 public ghost_totalYieldInjected;

    constructor() {
        _admin = makeAddr("vault_admin");
        for (uint256 i = 0; i < ACTOR_COUNT; i++) {
            _actors[i] = makeAddr(string(abi.encodePacked("vault_actor", i)));
        }

        asset = new MockERC20("USDC", "USDC", 6);
        VaultMockACL acl = new VaultMockACL();

        vault = new GiveVault4626();
        vm.prank(_admin);
        vault.initialize(
            address(asset),
            "Give USDC Vault",
            "gUSDC",
            _admin,
            address(acl),
            address(vault) // implementation (self-reference is fine in tests)
        );
    }

    // ── Handler actions ──────────────────────────────────────────────

    /// @notice Deposit assets into the vault for a given actor.
    function deposit(uint8 actorSeed, uint256 assets) external {
        address actor = _actors[actorSeed % ACTOR_COUNT];
        assets = bound(assets, 1, 100_000e6);

        asset.mint(actor, assets); // Ensure actor always has enough tokens

        vm.startPrank(actor);
        asset.approve(address(vault), assets);
        vault.deposit(assets, actor);
        vm.stopPrank();

        ghost_totalDeposited += assets;
    }

    /// @notice Withdraw a portion of an actor's position.
    function withdraw(uint8 actorSeed, uint256 assets) external {
        address actor = _actors[actorSeed % ACTOR_COUNT];
        uint256 maxW = vault.maxWithdraw(actor);
        if (maxW == 0) return;

        assets = bound(assets, 1, maxW);

        vm.prank(actor);
        vault.withdraw(assets, actor, actor);
        ghost_totalWithdrawn += assets;
    }

    /// @notice Redeem a portion of an actor's shares.
    function redeem(uint8 actorSeed, uint256 shares) external {
        address actor = _actors[actorSeed % ACTOR_COUNT];
        uint256 maxR = vault.maxRedeem(actor);
        if (maxR == 0) return;

        shares = bound(shares, 1, maxR);

        vm.prank(actor);
        uint256 assets = vault.redeem(shares, actor, actor);
        ghost_totalWithdrawn += assets;
    }

    /// @notice Inject yield by minting tokens directly into the vault
    ///         (simulates yield accrual that would normally come from an adapter).
    function injectYield(uint256 amount) external {
        if (vault.totalSupply() == 0) return; // No-op: yield with no shareholders is meaningless
        amount = bound(amount, 1, 100_000e6);
        asset.mint(address(vault), amount);
        ghost_totalYieldInjected += amount;
    }

    // ── Getters ──────────────────────────────────────────────────────

    function actor(uint8 idx) external view returns (address) {
        return _actors[idx % ACTOR_COUNT];
    }
}
