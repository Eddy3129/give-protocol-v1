# Slither Findings (Phase 2 — Full Run)

Date: 2026-02-21
Tool: `slither-analyzer 0.11.5`
Command: `make slither` (`uv run slither . --compile-force-framework foundry --filter-paths "lib/,node_modules/" --exclude-dependencies`)
Total results: **109** across 104 contracts (101 detectors)

---

## Scope

- Path: `.`
- Excluded: `lib/`, `node_modules/`
- `--exclude-dependencies` active

---

## Triage Key

| Status | Meaning |
|--------|---------|
| **DISMISSED — false positive** | Slither misreads the pattern; code is safe |
| **DISMISSED — mock/test only** | Finding is in `src/mocks/`; never deployed |
| **DISMISSED — intentional** | Known trade-off, documented and accepted |
| **ACCEPTED** | Real issue; fix required before mainnet |

---

## HIGH findings

### H-01 `arbitrary-send-eth` — CampaignRegistry.approveCampaign

- **Location:** `src/registry/CampaignRegistry.sol#435`
- **Detector:** `arbitrary-send-eth`
- **Summary:** ETH sent to `proposer` via `.call{value: depositAmount}()`.
- **Triage:** DISMISSED — intentional
- **Reason:** Proposer is the campaign submitter by design. The deposit amount is zeroed (`s.campaigns[campaignId].submissionDeposit = 0`) before the call — CEI pattern applied. The call reverts on failure via `DepositTransferFailed`. Access is gated by `ROLE_CAMPAIGN_ADMIN`. The recipient is not user-controlled at call time; it was recorded at `submitCampaign`.

### H-02 `arbitrary-send-erc20` — MockYieldAdapter.invest

- **Location:** `src/mocks/MockYieldAdapter.sol#134`
- **Detector:** `arbitrary-send-erc20`
- **Summary:** `safeTransferFrom(_vault, address(this), assets)` — arbitrary `from`.
- **Triage:** DISMISSED — mock/test only
- **Reason:** `MockYieldAdapter` is in `src/mocks/` and is never deployed to mainnet. The `_vault` binding is set at construction and is the vault that controls this adapter.

---

## MEDIUM findings

### M-01 `reentrancy-balance` — GiveVault4626._ensureSufficientCash

- **Location:** `src/vault/GiveVault4626.sol#529-546`
- **Detector:** `reentrancy-balance`
- **Summary:** Balance read before `adapter.divest()` external call; `loss` computed from pre-call balance may be stale.
- **Triage:** DISMISSED — false positive
- **Reason:** `_ensureSufficientCash` is called only from `withdraw`/`redeem` which carry `nonReentrant`. The balance is read to compute a shortfall before the divest, and `loss` is re-derived from the returned value (not the pre-call balance) at line 544. The adapter itself is `onlyVault` + `nonReentrant`, making reentrant divest impossible.

### M-02 `reentrancy-balance` — AaveAdapter.divest

- **Location:** `src/adapters/AaveAdapter.sol#229-267`
- **Detector:** `reentrancy-balance`
- **Summary:** aToken balance read before `aavePool.withdraw()`.
- **Triage:** DISMISSED — false positive
- **Reason:** `divest` is `onlyVault` + `nonReentrant`. Aave V3 pool is a trusted, audited external contract. The pre-call balance is used only to compute slippage; the final `totalInvested` update uses `returned` (the actual withdrawn amount), not the stale balance.

### M-03 `reentrancy-no-eth` — PendleAdapter.divest

- **Location:** `src/adapters/kinds/PendleAdapter.sol#73-104`
- **Detector:** `reentrancy-no-eth`
- **Summary:** `deposits` written after Pendle router swap call.
- **Triage:** DISMISSED — false positive
- **Reason:** `divest` is `onlyVault`. `PendleAdapter` has no `nonReentrant` but the Pendle router is a trusted external contract and the `onlyVault` guard prevents any external party from calling this directly. The deposit reduction (`deposits -= principalReduced`) on line 101 follows immediately after the swap with no user-accessible state path in between.

### M-04 `reentrancy-no-eth` — AaveAdapter.harvest

- **Location:** `src/adapters/AaveAdapter.sol#276-305`
- **Detector:** `reentrancy-no-eth`
- **Summary:** `totalInvested` written after `aavePool.withdraw()`.
- **Triage:** DISMISSED — false positive
- **Reason:** `harvest` is `onlyVault` + `nonReentrant`. Aave pool is trusted. State update at line 288 is the canonical post-call pattern.

### M-05 `divide-before-multiply` — GrowthAdapter.divest

- **Location:** `src/adapters/kinds/GrowthAdapter.sol#94-114`
- **Detector:** `divide-before-multiply`
- **Summary:** `normalized = (assets * 1e18) / growthIndex` then `returned = (normalized * growthIndex) / 1e18`.
- **Triage:** DISMISSED — intentional arithmetic
- **Reason:** This is the index normalization round-trip for growth-adjusted accounting. The division-then-multiplication is intentional: converting to normalized units and back. Rounding loss is bounded by 1 unit of precision and is capped by `totalDeposits` as an upper bound. Documented in the adapter design.

### M-06 `divide-before-multiply` — PendleAdapter.divest

- **Location:** `src/adapters/kinds/PendleAdapter.sol#73-104`
- **Detector:** `divide-before-multiply`
- **Summary:** `ptToSell = (ptBalance * assets) / deposits` then `principalReduced = (deposits * ptToSell) / ptBalance`.
- **Triage:** DISMISSED — intentional arithmetic
- **Reason:** Proportional PT liquidation math. The divide-then-multiply pattern computes the proportional share of PT to sell, then maps it back to deposited principal. Rounding error is bounded and favours the vault (under-returns rather than over-returns). Consistent with Pendle integration patterns.

### M-07 `incorrect-equality` — AaveAdapter (aTokenBalance == 0)

- **Location:** `src/adapters/AaveAdapter.sol#233, #320`
- **Detector:** `incorrect-equality`
- **Summary:** Strict equality `aTokenBalance == 0` used as an early-return guard.
- **Triage:** DISMISSED — intentional
- **Reason:** aToken balance for a depositing vault should be exactly zero only if no funds are invested. aTokens are rebasing and will only ever be zero if no deposit has occurred. This is an early-exit guard, not a conditional branch on an approximate value.

### M-08 `incorrect-equality` — PendleAdapter (ptBalance == 0, ptToSell == 0, etc.)

- **Location:** `src/adapters/kinds/PendleAdapter.sol#77, #83, #97, #98`
- **Detector:** `incorrect-equality`
- **Summary:** Multiple strict equalities in divest.
- **Triage:** DISMISSED — intentional
- **Reason:** PT tokens are discrete ERC-20 balances. Zero checks guard against division-by-zero and no-op swaps. These are correct guards, not floating-point approximations.

### M-09 `incorrect-equality` — CampaignRegistry.finalizeStakeExit (pendingWithdrawal == 0)

- **Location:** `src/registry/CampaignRegistry.sol#692`
- **Detector:** `incorrect-equality`
- **Summary:** `stake.pendingWithdrawal == 0` used as guard.
- **Triage:** DISMISSED — intentional
- **Reason:** `pendingWithdrawal` is an integer amount set by `requestStakeExit`. Zero means no exit was requested. Strict equality is correct here.

### M-10 `incorrect-equality` — GiveVault4626.emergencyWithdrawUser (assets == 0)

- **Location:** `src/vault/GiveVault4626.sol#495`
- **Detector:** `incorrect-equality`
- **Summary:** `assets == 0` revert guard.
- **Triage:** DISMISSED — intentional
- **Reason:** Zero-amount withdrawal guard. Correct usage; assets is computed from shares and should be exact.

### M-11 `incorrect-equality` — MockAavePool.accrueYield (scaledSupply == 0)

- **Location:** `src/mocks/MockAavePool.sol#228`
- **Detector:** `incorrect-equality`
- **Summary:** Strict equality in mock.
- **Triage:** DISMISSED — mock/test only
- **Reason:** `MockAavePool` is test infrastructure, never deployed.

---

## LOW findings

### L-01 `reentrancy-benign` — Multiple locations

- **Locations:** AaveAdapter (invest, divest, harvest, emergencyWithdraw), PendleAdapter (invest, divest, emergencyWithdraw), StrategyManager (_performRebalance, setActiveAdapter, updateVaultParameters), MockAavePool (supply, withdraw)
- **Detector:** `reentrancy-benign`
- **Summary:** State written after external call, but no ETH/token drain possible.
- **Triage:** DISMISSED — false positive
- **Reason:** All adapter functions are `onlyVault` + `nonReentrant` or call trusted contracts (Aave V3, Pendle router). StrategyManager functions are access-controlled. MockAavePool is test-only. Slither flags these as "benign" because no value extraction path exists.

### L-02 `reentrancy-events` — Multiple locations

- **Locations:** EmergencyModule, StrategyManager, CampaignRegistry.approveCampaign, CampaignVaultFactory, PendleAdapter, GiveVault4626, MockAavePool
- **Detector:** `reentrancy-events`
- **Summary:** Events emitted after external calls, could be emitted from incorrect state in a reentrancy attack.
- **Triage:** DISMISSED — false positive
- **Reason:** All affected functions are either (a) protected by `nonReentrant`, (b) `onlyVault`-gated with a trusted caller, or (c) in mock contracts. Event ordering after external calls is a cosmetic issue only when no state inconsistency is reachable. No exploit path exists.

### L-03 `uninitialized-local` — StrategyRegistry, EmergencyModule

- **Locations:**
  - `src/registry/StrategyRegistry.sol#336` — `removed` bool in `unregisterStrategyVault`
  - `src/modules/EmergencyModule.sol#188` — `params` struct in `_emergencyWithdraw`
- **Detector:** `uninitialized-local`
- **Summary:** Local variables declared but not explicitly initialized.
- **Triage:** DISMISSED — false positive
- **Reason:** Solidity zero-initializes all local variables. `removed` starts as `false` (correct default for a flag tracking whether removal occurred). `params` struct starts with all fields zeroed which is the correct empty state before decoding.

### L-04 `unused-return` — PendleAdapter

- **Locations:** `src/adapters/kinds/PendleAdapter.sol#67, #91, #119-120`
- **Detector:** `unused-return`
- **Summary:** Return values from Pendle router calls partially ignored.
- **Triage:** DISMISSED — intentional
- **Reason:** `invest` ignores the swap output because the adapter tracks invested principal via `deposits`, not swap output tokens (which are PT tokens held by the adapter). `divest` and `emergencyWithdraw` destructure the tuple but discard the second and third elements which are routing metadata not needed post-swap.

### L-05 `shadowing-local` — All adapter constructors

- **Locations:** ClaimableYieldAdapter, CompoundingAdapter, GrowthAdapter, ManualManageAdapter, PTAdapter, PendleAdapter constructors
- **Detector:** `shadowing-local`
- **Summary:** Constructor parameters `adapterId`, `asset`, `vault` shadow parent state variable/functions.
- **Triage:** DISMISSED — false positive
- **Reason:** Constructor parameters are passed directly to `AdapterBase` via `super(adapterId, asset, vault)`. The shadowing is within the constructor scope only and has no runtime effect. This is the standard pattern for constructor parameter forwarding.

### L-06 `missing-zero-check` — CampaignVaultFactory, CampaignRegistry, Mocks

- **Locations:**
  - `CampaignVaultFactory.sol#170` — vault address from CREATE2
  - `CampaignRegistry.sol#431` — proposer in `approveCampaign`
  - `MockAToken` and `MockYieldAdapter` constructors
- **Detector:** `missing-zero-check`
- **Summary:** Address variables assigned without explicit `!= address(0)` check.
- **Triage:** DISMISSED
- **Reason:**
  - `CampaignVaultFactory`: `vault` is the result of `new ERC1967Proxy(...)` — will revert if deployment fails, never returns zero.
  - `CampaignRegistry.approveCampaign`: `proposer` is read from storage set during `submitCampaign`; zero-address submissions are rejected at submit time.
  - Mocks: test infrastructure, never deployed.

### L-07 `calls-loop` — StrategyManager._findBestAdapter

- **Location:** `src/manager/StrategyManager.sol#441-466`
- **Detector:** `calls-loop`
- **Summary:** `IYieldAdapter(adapter).totalAssets()` called inside a loop over registered adapters.
- **Triage:** DISMISSED — intentional
- **Reason:** `_findBestAdapter` is called during rebalance, which is a keeper operation (not user-facing). The adapter set is small (bounded by `StrategyRegistry` capacity, typically 1–5 adapters). Each `totalAssets()` is a view call. The unbounded loop concern does not apply at realistic adapter counts.

### L-08 `timestamp` — PTAdapter, NGORegistry, StrategyManager, PayoutRouter, CampaignRegistry, GiveVault4626, MockAavePool

- **Detector:** `timestamp`
- **Summary:** `block.timestamp` used for time-sensitive comparisons.
- **Triage:** DISMISSED — intentional
- **Reason:** All timestamp usages are for:
  - Grace periods (24h+ windows — miner manipulation of ~15s is irrelevant)
  - Timelock delays (24h+ — same reasoning)
  - Rebalance intervals (daily — same reasoning)
  - Voting windows (multi-day — same reasoning)
  No finding has a sub-minute sensitivity window where miner timestamp manipulation would matter.

---

## INFORMATIONAL findings

### I-01 `assembly` — GiveStorage, StorageLib, StrategyManager

- **Locations:** `src/storage/GiveStorage.sol#217-219`, `src/storage/StorageLib.sol#49-51`, `src/manager/StrategyManager.sol#523-525`
- **Triage:** DISMISSED — intentional
- **Reason:** Diamond storage slot calculation requires inline assembly (`sload`/`sstore` at keccak256-derived slot). `StrategyManager` uses assembly for dynamic array packing in `getApprovedAdapters`. All usages are standard, audited patterns.

### I-02 `low-level-calls` — CampaignVaultFactory, CampaignRegistry, GiveVault4626, MockAavePool, MockAToken

- **Triage:** DISMISSED — intentional
- **Reason:**
  - `CampaignVaultFactory`: Uses low-level calls to avoid circular imports between factory and vault/registry interfaces. All return values checked.
  - `CampaignRegistry.approveCampaign`: ETH refund to proposer must use low-level call (ETH transfer). Return checked, reverts on failure.
  - `GiveVault4626.redeemETH/withdrawETH`: ETH delivery to receiver requires low-level call. Return checked.
  - Mocks: test infrastructure.

### I-03 `missing-inheritance` — MockAavePool, StrategyRegistry

- **Locations:** MockAavePool should inherit IPool, MockAToken should inherit IAToken, StrategyRegistry should inherit IStrategyRegistry
- **Triage:** DISMISSED — accepted trade-off
- **Reason:** MockAavePool/MockAToken are mocks; explicit interface inheritance would require matching all Aave interface signatures which is unnecessary for test fidelity. StrategyRegistry's IStrategyRegistry is a lightweight internal interface used only by CampaignRegistry for import resolution.

### I-04 `naming-convention` — AaveAdapter, GiveProtocolCore, MockAToken, VaultTokenBase

- **Triage:** DISMISSED — intentional
- **Reason:** `_bps` parameter prefix is a project convention. `_aclManager` uses underscore to distinguish the parameter from the state variable. `UNDERLYING_ASSET` and `POOL` follow the Aave interface naming standard. `__VaultTokenBase_init` follows OZ's double-underscore initializer naming convention.

### I-05 `redundant-statements` — GiveProtocolCore, MockAavePool

- **Locations:** `src/core/GiveProtocolCore.sol#350` (`newImplementation`), `src/mocks/MockAavePool.sol#121` (`referralCode`)
- **Triage:** DISMISSED — informational
- **Reason:** `newImplementation` in `_authorizeUpgrade` is referenced as a no-op to satisfy the override signature. `referralCode` in `MockAavePool.supply` is unused by design (mock doesn't track referrals).

### I-06 `immutable-states` — MockERC20, MockAToken

- **Locations:** `src/mocks/MockAavePool.sol#253-256` (`decimals`, `UNDERLYING_ASSET`, `POOL`), `src/mocks/MockERC20.sol#12` (`_decimals`)
- **Triage:** DISMISSED — mock/test only
- **Reason:** Mock contracts are not gas-optimized by design.

---

## Summary

| Severity | Total | Dismissed | Accepted |
|----------|-------|-----------|---------|
| High | 2 | 2 | 0 |
| Medium | 11 | 11 | 0 |
| Low | 8 | 8 | 0 |
| Informational | 6 | 6 | 0 |
| **Total** | **27** | **27** | **0** |

**Confirmed issues requiring code changes before mainnet: none.**

---

## Semgrep Results

Command: `semgrep --config auto src/`
Rules run: 69
Targets: 36 files under `src/`
Findings: **0**

---

## Phase Outcome

- All Slither findings triaged and dismissed (false positives, intentional patterns, or mock-only code).
- No code changes required from this scan.
- Deployment gate for static analysis: **PASSED**.
