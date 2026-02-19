// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @notice Base mainnet addresses used across all fork tests.
///         Verified against on-chain state at block 27_000_000.
library ForkAddresses {
    // ── Chain ─────────────────────────────────────────────────────────
    uint256 internal constant CHAIN_ID = 8453; // Base mainnet

    // ── Aave V3 ──────────────────────────────────────────────────────
    address internal constant AAVE_POOL = 0xA238Dd80C259a72e81d7e4664a9801593F98d1c5;
    address internal constant AAVE_ORACLE = 0x2Cc0Fc26eD4563A5ce5e8bdcfe1A2878676Ae156;

    // ── USDC ─────────────────────────────────────────────────────────
    address internal constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    address internal constant AUSDC = 0x4e65fE4DbA92790696d040ac24Aa414708F5c0AB;

    // ── WETH ─────────────────────────────────────────────────────────
    // WETH on Base — used by depositETH/withdrawETH vault flow
    address internal constant WETH = 0x4200000000000000000000000000000000000006;

    // ── wstETH ───────────────────────────────────────────────────────
    // Lido Wrapped Staked ETH on Base (bridged from Ethereum mainnet)
    // Value appreciates over time as staking rewards accrue — use with CompoundingAdapter
    address internal constant WSTETH = 0xc1CBa3fCea344f92D9239c08C0568f6F2F0ee452;

    // ── Pendle ───────────────────────────────────────────────────────
    // PendleRouterV4 — same address across all chains (CREATE2 deployment)
    // Used by a future PendleAdapter to buy/sell PT tokens
    // NOTE: Current PTAdapter is simulation-only (no PendleRouter calls)
    address internal constant PENDLE_ROUTER = 0x888888888889758F76e7103c6CbF23ABbF58F946;
    // Market factory — query for current active PT markets on Base
    address internal constant PENDLE_MARKET_FACTORY_V6 = 0x81E80A50E56d10C501fF17B5Fe2F662bd9EA4590;
}
