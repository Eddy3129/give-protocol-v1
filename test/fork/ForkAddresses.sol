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
    address internal constant PENDLE_ROUTER = 0x888888888889758F76e7103c6CbF23ABbF58F946;
    // Market factory — query for current active PT markets on Base
    address internal constant PENDLE_MARKET_FACTORY_V6 = 0x81E80A50E56d10C501fF17B5Fe2F662bd9EA4590;

    // ── Pendle PT-yoUSD (USDC underlying) ────────────────────────────
    // Floating PT TVL ~$702k, yield range 6%-26%
    address internal constant PENDLE_YOUSD_MARKET = 0xA679ce6D07cbe579252F0f9742Fc73884b1c611c;
    address internal constant PENDLE_YOUSD_UNDERLYING = 0x0000000f2eB9f69274678c76222B35eEc7588a65;
    address internal constant PENDLE_YOUSD_SY = 0xE181Aed8E14469231618504dF46E8C069314589B;
    address internal constant PENDLE_YOUSD_PT = 0x0177055f7429D3bd6B19f2dd591127DB871A510e;
    address internal constant PENDLE_YOUSD_YT = 0x1658a0A2E5D06b0260Cee8339bc08F07E374a5e2;

    // ── Pendle PT-yoETH (WETH underlying) ────────────────────────────
    // Floating PT TVL ~$582k, yield range 3%-13%
    address internal constant PENDLE_YOETH_MARKET = 0x5d6E67FcE4aD099363D062815B784d281460C49b;
    address internal constant PENDLE_YOETH_UNDERLYING = 0x3A43AEC53490CB9Fa922847385D82fe25d0E9De7;
    address internal constant PENDLE_YOETH_SY = 0xE574de45b4eA2c5DB7Dd6F4074349F270EE97C64;
    address internal constant PENDLE_YOETH_PT = 0x1A5c5eA50717a2ea0e4F7036FB289349DEaAB58b;
    address internal constant PENDLE_YOETH_YT = 0x0EC1292d5cE7220Be4C8e3A16efF7DDD165c9111;
}
