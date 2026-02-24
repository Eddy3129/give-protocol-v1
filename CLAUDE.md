# GIVE Protocol — Concise Status Summary

Last updated: 2026-02-23

## Project Snapshot

No-loss donation protocol built on ERC-4626 vaults.

- Donors deposit principal
- Yield is routed to campaigns/NGOs via PayoutRouter
- Principal remains redeemable

## Stack

- Solidity `0.8.34`
- Foundry
- OpenZeppelin v5
- UUPS proxies
- Diamond Storage
- Mainnet target: Base

## Mandatory Deployment Gates

1. `forge test -v` passes (no failures)
2. PayoutRouter pull accumulator model is active (push loop removed)
3. Slither + Semgrep triaged with no unaccepted High findings
4. Fuzz + invariant suites exist and pass
5. Base fork suites pass for live assumptions
6. Tenderly scenario validation complete

---

## Update Log (Concise)

## Current Snapshot (2026-02-24)

- Frontend strict E2E is stable (`56/56`) via `make vitest`.
- Deployment scripts are hardened (broadcaster guardrails, env checks, canonical role grants).
- `PendleAdapter` supports `tokenOut` for yield-bearing SY markets (yoUSD/yoETH).
- Fork suite includes critical upgrade-path checks (`ForkTest11_UpgradeCriticalPaths`).
- Latest coverage run baseline: **438 tests passed**, no failures (unit+integration coverage profile).

## Delivered Recently

- Replaced manual `.s.sol` operations flow with Viem + Vitest runtime operations suite.
- Standardized frontend E2E command surface (`make vitest`; strict runtime only).
- Closed deployment/runtime assumptions around role-admin chain, artifact selection, and vault activation wiring.
- Expanded fork coverage for Pendle market variants and critical-path upgrade safety.

## Historical Log (Condensed)

### Update O — Strict E2E + Deployment Hardening (Complete)

- Frontend strict E2E stabilized on live simulation (`56/56`).
- Fixed role-admin chain assumptions, deployment artifact selection, and fresh vault activation wiring.
- Hardened deployment scripts (`ALLOW_DEFAULT_BROADCAST` guardrails, env checks, canonical factory role grants).
- Standardized ops surface (`make vitest` public; strict-only runtime path).

### Phases 0–5 Summary (Complete)

- Security baseline established (Slither + Semgrep triage, ACL/reentrancy/flash-loan checks).
- Pull-based PayoutRouter accumulator model active in production path.
- Adapter integration coverage expanded (Aave, compounding paths, Pendle standard + yield-bearing markets).
- Fork validation expanded (live protocol assumptions, upgrade critical paths).
- Coverage hardening completed for core risk contracts with `--ir-minimum` profile standardization.

## Phase 6 — Production Readiness (In Progress)

### Done

- Mainnet deployment runbook execution validated in simulation environments.
- Viem/Vitest operations suite delivered and running as the operational validation path.

### Open

- Multi-RPC fallback validation (`BASE_RPC_URL_FALLBACK`) for degraded primary + dual-outage UX.
- Revert-to-UX mapping finalization (human-readable frontend errors).
- Basescan verification flow (`VERIFY_CONTRACTS=true`) full-path validation.

---

## Pending / Future Improvements (Only Uncovered Items)

### P0 — Must Close Before Mainnet

- Validate multi-RPC fallback behavior and user-facing error on dual endpoint outage.
- Complete Basescan verification path for proxies + implementations (`VERIFY_CONTRACTS=true`).
- Finalize frontend revert decoding for core selectors (`ERC4626ExceededMaxRedeem`, `InsufficientCash`, `ExcessiveLoss`, `EnforcedPause`, `GracePeriodExpired`, `ZeroAmount`).

### P1 — Audit / Coverage Follow-ups

- Continue fork/fuzz closure for `AaveAdapter` and ETH wrapper paths (branch-heavy, fork-gated).
- Add EmergencyModule branch coverage for:
  - `EmergencyAlreadyActive`, `EmergencyNotActive`, `NoActiveAdapter`
  - `clearAdapter: false` retention path
  - `data.length == 0` default parameter path
  - Full sequence: Pause → Withdraw(clear=false) → Unpause

### P1 — RiskModule Scope Clarity (Audit Note)

`RiskModule` stores a full risk parameter set but only enforces `maxDeposit` at runtime.
The following parameters are written to diamond storage but have no on-chain enforcement anywhere
in the current codebase:

- `ltvBps` — stored, never read back during any operation
- `liquidationThresholdBps` — stored, never read back
- `liquidationPenaltyBps` — stored, never read back
- `borrowCapBps` / `maxBorrow` — stored, `enforceBorrowLimit` exists but is never called
- `depositCapBps` — stored, not used by `enforceDepositLimit` (which uses `maxDeposit` instead)

**Why this is currently correct:** GIVE Protocol is a pure yield-routing vault — donors deposit,
yield flows to NGOs, principal stays intact. There is no lending, borrowing, or liquidation in
the current design. `maxDeposit` (TVL cap) is the only risk parameter that matters today.

**Audit note:** An auditor reading `ltvBps` and `liquidationThresholdBps` in storage may spend
time searching for liquidation logic that does not exist. Should be explicitly documented in
audit scope to avoid false findings.

**Recommended next step:** either remove unused fields now, or annotate them as
reserved for lending-adapter integration (`@dev NOTE`) to avoid audit ambiguity.

### P2 — PT Vault Product Constraints

**Problem:** PT vaults do not handle early withdrawal well. `PendleAdapter.divest()` calls
`swapExactPtForToken` which sells PT on the secondary AMM at a discount. The current AMM
spread on PT-yoUSD is ~6.4%, which exceeds the vault's `maxLossBps` cap (max 5%), causing
every early `redeem` to revert with `ExcessiveLoss`. Additionally, `swapExactPtForToken`
reverts entirely post-maturity — the correct path after expiry is `exitPostExpToToken`, which
the adapter does not expose. In practice, early redemption is blocked by slippage and
post-maturity redemption requires admin intervention via `emergencyWithdrawFromAdapter`.

Furthermore, `harvest()` on `PendleAdapter` permanently returns `(0, 0)` since PT yield is
embedded in the PT price discount rather than streaming interest. This means `recordYield` is
never called, the per-share accumulator never advances, and no donations ever reach the NGO
from a PT vault during its lifetime — only at maturity when the discount is realised.

**Proposed path:**

1. Add maturity lock for `withdraw`/`redeem` pre-expiry.
2. Add post-maturity redemption path using `exitPostExpToToken`.
3. Add one-time maturity harvest accounting path for realised PT discount.

Until implemented, treat PT vaults as maturity-locked products in operator/user communications.

---

## Test Organization & Standards (Formalized)

### **Test Suite Structure**

Tests are formally organized by scope, intent, and test type:

| Category        | Directory           | Files | Purpose                                                                | Example                              | Naming                       |
| --------------- | ------------------- | ----- | ---------------------------------------------------------------------- | ------------------------------------ | ---------------------------- |
| **Base**        | `test/base/`        | 3     | Shared deployment fixtures, 3-phase provisioning                       | Base01_DeployCore.t.sol              | `Base0{1,2,3}_Deploy*.t.sol` |
| **Unit**        | `test/unit/`        | 20    | Single-contract functionality, property validation                     | TestContract01_ACLManager.t.sol      | `TestContract{NN}_*.t.sol`   |
| **Integration** | `test/integration/` | 2     | Full workflow cycles, end-to-end scenarios                             | TestAction01_CampaignLifecycle.t.sol | `TestAction{NN}_*.t.sol`     |
| **Fork**        | `test/fork/`        | 11    | Live protocol interactions + critical-path upgrade checks on Base fork | ForkTest01_AaveAdapter               | `ForkTest{NN}_*.fork.t.sol`  |
| **Fuzz**        | `test/fuzz/`        | 4     | Stateless/stateful property testing                                    | FuzzTest03_PayoutRouter              | `FuzzTest{NN}_*.t.sol`       |
| **Invariant**   | `test/invariant/`   | 3     | Multi-step protocol invariants with handlers                           | InvariantTest02_PayoutRouter         | `InvariantTest{NN}_*.t.sol`  |

### **Test File Header Convention**

All test files MUST include Solidity NatSpec documentation:

```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title   TestName
 * @author  GIVE Labs
 * @notice  One-liner describing test scope
 * @dev     Bullet-point list of what is tested:
 *          - Specific path A
 *          - Specific path B
 *          - Error conditions
 */
```

**Examples:**

- **Unit**: "Comprehensive test for PayoutRouter fee timelock logic"
- **Fork**: "End-to-end vault cycle against live Aave V3 on Base mainnet"
- **Fuzz**: "Stateless property-based fuzzing for AaveAdapter invest/divest"

### **Test Counts (Current - Update M)**

| Type            | Count       | Example                                                                                                                                       | Scope                             |
| --------------- | ----------- | --------------------------------------------------------------------------------------------------------------------------------------------- | --------------------------------- |
| **Base env**    | 3           | Base01, Base02, Base03                                                                                                                        | Deployment fixtures only          |
| **Unit**        | 407 cases   | 20 files from adapterKinds to UUPSUpgradeAuth                                                                                                 | Single-contract, deterministic    |
| **Integration** | ~400+ cases | Campaign lifecycle, multi-strategy ops                                                                                                        | Full workflows, real dependencies |
| **Fork**        | 11 suites   | Aave (USDC/WETH/ETH), Pendle (yoUSD, yoETH, maturity/donor cycle), checkpoint voting, multi-vault, campaign lifecycle, upgrade critical paths | Live mainnet protocols            |
| **Fuzz**        | 4 suites    | Router, vault, adapters, registry                                                                                                             | Property-based bounded runs       |
| **Invariant**   | 3 suites    | Router, vault, registry                                                                                                                       | Multi-step invariant handlers     |
| **Total**       | 407         | Unit + integration only                                                                                                                       | Production coverage               |

### **Test Documentation Standards**

1. **Naming**: File + contract name must match (e.g., `FuzzTest03_PayoutRouter.t.sol` → `FuzzTest03_PayoutRouter`)
2. **Headers**: All test files have proper @title/@notice/@dev comments (enforced via linting)
3. **Comments**: Inline comments explain non-obvious test setup or assertion logic
4. **Mocks**: All per-test mocks (MockACL, MockRegistry) defined in same file with `Mock*` prefix
5. **Fixtures**: Shared fixtures (ACLManager, vaults) defined in `test/base/` and inherited

### **Coverage Profile (Update M)**

| Metric       | Overall    | PayoutRouter | GiveVault4626 |
| ------------ | ---------- | ------------ | ------------- |
| Lines        | 60.43%     | 88.72%       | 78.79%        |
| Statements   | 61.00%     | 88.85%       | 81.07%        |
| **Branches** | **49.23%** | **87.80%**   | **83.05%**    |
| Functions    | 62.62%     | 88.10%       | 71.70%        |

**Note:** Coverage runs unit + integration only (`--no-match-path 'test/fork/**:test/fuzz/**:test/invariant/**'`).
Fork/fuzz/invariant are validation layers, not coverage contributors.

---

## Core Commands

### Main validation

```bash
forge test -v
```

### Unit

```bash
forge test --match-path "test/unit/**" -v
```

### Fast iteration (no fork/fuzz/invariant)

```bash
FOUNDRY_PROFILE=dev-fast forge test --no-match-path "test/fork/**:test/fuzz/**:test/invariant/**" -v
```

### Fuzz

```bash
forge test --match-path "test/fuzz/**" -v --fuzz-seed 0x1337
```

### Invariant

```bash
forge test --match-path "test/invariant/**" -v
```

### Fork (Base)

```bash
forge test --match-path "test/fork/ForkTest05_ForkSanity*" --fork-url $BASE_RPC_URL -v
forge test --match-path "test/fork/**" --fork-url $BASE_RPC_URL -v
```

### Update N — Test Naming Standardization (Complete)

All fork/fuzz/invariant tests now follow numbered naming and matching contract titles:

- Fork: `ForkTest01_*` … `ForkTest11_*` (11 suites, sequential)
- Fuzz: `FuzzTest01_*` … `FuzzTest04_*`
- Invariant: `InvariantTest01_*` … `InvariantTest03_*`

Validation:

- File names, contract declarations, and NatSpec `@title` fields are synchronized.
- Latest default run (`forge test`) remains green: 407 passed, 0 failed, 0 skipped (unit+integration).

### Frontend integration

```bash
# Local Anvil — full lifecycle (deploy first)
npm run deploy:local:all
npm run frontend:smoke:local

# Live Base RPC — protocol connectivity only
BASE_RPC_URL=... npm run frontend:smoke:rpc

# Base mainnet fork — full lifecycle against real USDC/Aave
BASE_RPC_URL=... npm run frontend:smoke:fork

# Other chains (needs ARBITRUM_RPC_URL / OPTIMISM_RPC_URL)
npm run frontend:smoke:rpc:arbitrum
npm run frontend:smoke:fork:arbitrum
```

### Coverage

```bash
# Summary table (unit + integration only)
FOUNDRY_PROFILE=coverage forge coverage --ir-minimum --report summary \
  --no-match-path "test/fork/**:test/fuzz/**:test/invariant/**"

# LCOV artifact for tooling
FOUNDRY_PROFILE=coverage forge coverage --ir-minimum --report lcov \
  --no-match-path "test/fork/**:test/fuzz/**:test/invariant/**"
```

> `--ir-minimum` is required permanently: OZ's `__ERC20_init` uses inline assembly
> that hits the 16-slot stack limit when `optimizer=false, via_ir=false`.

### Static analysis

```bash
slither . --compile-force-framework foundry --filter-paths "lib/,node_modules/" --exclude-dependencies --json slither-report.json
semgrep --config auto src/
```

---

## Environment Notes

- `BASE_RPC_URL` should point to private RPC for reliability
- `ForkBase.t.sol` includes public fallback for local convenience
- Pendle fork smoke (`ForkTest07`/`ForkTest08`) uses hardcoded addresses from `ForkAddresses.sol` for yoUSD/yoETH market coverage — no extra env vars required
- `Deploy02_VaultsAndAdapters.s.sol` reads `PENDLE_TOKEN_OUT_ADDRESS` for the 7th PendleAdapter constructor arg; defaults to `USDC_ADDRESS` when unset (correct for standard PT-aUSDC markets)

### PendleAdapter tokenOut — Market Types

| Market type   | Example  | `asset_` (invest in) | `tokenOut_` (receive on divest) |
| ------------- | -------- | -------------------- | ------------------------------- |
| Standard      | PT-aUSDC | USDC                 | USDC (same)                     |
| Yield-bearing | PT-yoUSD | USDC                 | yoUSD (different)               |
| Yield-bearing | PT-yoETH | WETH                 | yoETH (different)               |

The SY contract's `getTokensOut()` determines the valid `tokenOut_` values. Passing the wrong token causes `SYInvalidTokenOut` revert. Verify with:

```bash
cast call <SY_ADDRESS> "getTokensOut()(address[])" --rpc-url $BASE_RPC_URL
```
