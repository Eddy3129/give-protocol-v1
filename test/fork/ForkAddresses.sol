// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @notice Base mainnet addresses used across all fork tests.
///         Verified against on-chain state at block 27_000_000.
library ForkAddresses {
    // ── Aave V3 ──────────────────────────────────────────────────────
    address internal constant AAVE_POOL    = 0xA238Dd80C259a72e81d7e4664a9801593F98d1c5;
    address internal constant AAVE_ORACLE  = 0x2Cc0Fc26eD4563A5ce5e8bdcfe1A2878676Ae156;

    // ── USDC ─────────────────────────────────────────────────────────
    address internal constant USDC         = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    address internal constant AUSDC        = 0x4e65fE4DbA92790696d040ac24Aa414708F5c0AB;

    // ── Chain ─────────────────────────────────────────────────────────
    uint256 internal constant CHAIN_ID     = 8453; // Base mainnet
}
