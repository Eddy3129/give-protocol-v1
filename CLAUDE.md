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

## Current Completion Snapshot

1. Strict frontend E2E is complete and passing (`56/56`) via `make vitest`.
2. Deployment scripts are hardened (broadcaster guards, env validation, canonical factory role grants).
3. Frontend E2E runtime is strict-only with explicit deployment artifact selection.
4. `Makefile` command surface is simplified (`make vitest` public, `frontend-e2e` internal override target).
5. `PendleAdapter` extended with `tokenOut` immutable to support yield-bearing Pendle markets (PT-yoUSD, PT-yoETH) where the SY redemption token differs from the deposit asset.
6. Fork suite trimmed to 8 high-value tests. `ForkTest11_PendleYoUSD` and `ForkTest12_PendleYoETH` added; `ForkTest03` (wstETH token-hold only), `ForkTest08` (PTAdapter no-op blocker), `ForkTest09` (mock-only gas test), and `ForkTest10` (env-gated duplicate) deleted.

## Completed Work (Phases 0–5)

The protocol has been fully stabilized, tested, and audited across multiple iterations:

1. **Security & Validation**
   - Slither priority detectors + Semgrep auto pass triaged.
   - Reentrancy, access control, and flash-loan protections verified.
   - PayoutRouter uses a scalable pull-based accumulator model for yield distribution.
2. **Coverage Hardening**
   - 407 unit+integration tests (plus fork/fuzz/invariant suites) all passing.
   - Strict coverage mandates met (>85% branches on critical contracts like Vault and Router).
   - `--ir-minimum` used consistently across coverage to bypass stack-too-deep in OZ initializable.
3. **Adapter Integrations & Forks**
   - Live fork validations complete for `AaveAdapter`, `CompoundingAdapterWstETH`, and `PendleAdapter`.
   - `PendleAdapter` supports both standard markets (`tokenOut == asset`) and yield-bearing markets (`tokenOut != asset`, e.g. yoUSD, yoETH). Constructor takes a 7th `tokenOut_` parameter.
   - `ForkTest11_PendleYoUSD` and `ForkTest12_PendleYoETH` validate full PT invest/divest/emergency/harvest cycles on Base mainnet against live Pendle V4 Router.
   - `ForkAddresses.sol` extended with PT-yoUSD and PT-yoETH market, PT, SY, YT, and underlying addresses.
   - Multi-chain configurations added (Arbitrum, Optimism).
4. **Viem Frontend Smoke**
   - Local, RPC, and Fork lifecycle tests passing via `viem-smoke.mjs`.

_For historical details of earlier updates, refer to previous git commits._

### Update O — Strict E2E + Deployment Hardening (Complete)

Recent production-readiness work closed the live strict Vitest blocker and hardened deployment assumptions:

1. **Strict E2E Live Pass**

- Frontend Vitest strict suite now passes end-to-end on BuildBear (`56/56`).
- Campaign lifecycle, deposit, preference, harvest, payout, redeem, invariant, and revert sections all green.

2. **Root Cause Closures**

- Fixed role-chain assumptions (`grantRole` requires role-admin authority).
- Fixed deployment artifact ambiguity (explicit `DEPLOYMENT_NETWORK`/`DEPLOYMENTS_FILE` pathing).
- Fixed fresh campaign-vault operationalization (router wiring + vault-bound adapter activation).
- Corrected access-control expectation for permissionless `harvest` behavior.

3. **Deployment Script Hardening**

- Added broadcaster preflight checks and `ALLOW_DEFAULT_BROADCAST` guardrails.
- Added env validation for required addresses and fee bounds.
- Added canonical role grants for `CampaignVaultFactory` (`ROLE_CAMPAIGN_ADMIN`, `ROLE_STRATEGY_ADMIN`).

4. **Ops Ergonomics**

- Frontend E2E is strict-only (non-strict path removed from runtime assertions).
- `Makefile` now exposes `make vitest` as the primary public frontend E2E command.
- Internal frontend target renamed to `frontend-e2e` and old `frontend-e2e-rpc-strict` removed.
- `.env.example` expanded to include strict frontend and deployment requirements.

---

---

## Phase 6 — Tenderly + Production Readiness (In Progress)

Phase 6 covers everything between "fork smoke passes" and "safe to deploy to mainnet".
None of this is covered by any prior phase.

### 6.1 — Tenderly Virtual TestNet scenarios (Replaced by 6.7)

_Note: The manual forge script scenarios have been deprecated in favor of an automated Viem/Vitest operations suite (Phase 6.7)._

Collect: trace links, gas evidence, event shapes — needed for release signoff.

### 6.2 — Multi-RPC fallback validation

The smoke test currently skips fallback when only one RPC is provided.
Needs a second endpoint (`BASE_RPC_URL_FALLBACK`) configured and validated:

- Primary RPC degraded → fallback kicks in transparently
- Both RPCs down → surfaced error is user-friendly, not a raw viem transport error

### 6.3 — Revert message UX audit

The smoke test confirms revert selectors (`0xb94abeec`) but not human-readable
messages. The dapp needs to decode and display actionable errors.

Map every revert the user can trigger to a display string:

| Revert                     | User-facing message                       |
| -------------------------- | ----------------------------------------- |
| `ERC4626ExceededMaxRedeem` | "Insufficient shares to redeem"           |
| `InsufficientCash`         | "Vault is rebalancing, try again shortly" |
| `ExcessiveLoss`            | "Withdrawal paused due to slippage"       |
| `EnforcedPause`            | "Vault is paused"                         |
| `GracePeriodExpired`       | "Emergency period ended, contact support" |
| `ZeroAmount`               | "Amount must be greater than zero"        |

### 6.4 — Mainnet deployment runbook (Done)

The forge scripts have been successfully executed against Tenderly Virtual TestNet and BuildBear, including `--sender` parameter matching to ensure CREATE address consistency between simulation and broadcast.

Post-deploy checklist: verify contracts on Basescan, confirm donationRouter wired, confirm authorizedCaller set.

### 6.5 — Contract verification on Basescan

`VERIFY_CONTRACTS=true` path in `BaseDeployment.verifyContract()` exists but is
untested. Validate that all proxies and implementations verify correctly:

```bash
VERIFY_CONTRACTS=true ETHERSCAN_API_KEY=... forge script script/Deploy01_Infrastructure.s.sol \
  --rpc-url $BASE_RPC_URL --broadcast --verify
```

### 6.6 (Lower Priority) — GAP-6 adapter fork suites

No dedicated fork suites yet for `GrowthAdapter`, `ClaimableYieldAdapter`,
`ManualManageAdapter`. Not a blocker — no live Base deployment target for
realistic fork behavior. Add when adapters have mainnet deployments to fork against.

### 6.7 — Viem + Vitest Operations Suite ✅ Delivered (Strict Runtime)

Forge operations scripts (`.s.sol`) have been deprecated. All protocol operations (Campaign Creation, Vault Deployment, Deposits, Withdrawals, Yield Harvests) are moving to a cohesive TypeScript + Viem + Vitest test suite.

This suite runs live against any configured RPC (Tenderly VTN, BuildBear, Anvil) simulating end-to-end Dapp interactions:

1. **Admin & Setup Flows**

- [x] Read dynamically deployed addresses from `deployments/<network>-latest.json`
- [x] Confirm Strategy Registry has targeted strategy (e.g. AaveUSDCStrategy)

2. **Campaign Lifecycle Flow**

- [x] Admin: Submit new campaign via `CampaignRegistry.submitCampaign(params)`
- [x] Admin: Approve the newly submitted campaign via `CampaignRegistry.approveCampaign(id)`
- [x] Admin: Deploy a new Vault for the campaign via `CampaignVaultFactory.deployCampaignVault()`

3. **User Action & Yield Flow**

- [x] User: Approve USDC spend for the new Vault
- [x] User: Deposit USDC into the Campaign Vault
- [x] RPC: Fast-forward time (e.g. 30 days) to simulate yield accrual
- [x] Vault: Call `harvest()` (or simulate bot executing it) to process accrued yield

4. **Distribution & Withdrawal Flow**

- [x] PayoutRouter: Verify NGO/Campaign share metrics increase properly
- [x] User: Redeem Vault shares and confirm correct return of principal + zero slippage loss

Validation command (strict):

```bash
make vitest
```

Optional explicit override command:

```bash
make frontend-e2e RPC_URL=... DEPLOYMENT_NETWORK=anvil
```

**Note:** This suite completely replaces the need for `.s.sol` scripts outside of initial deployment, ensuring maximum compatibility with frontend implementation code.

---

## Pending / Future Improvements (Only Uncovered Items)

### Coverage-Driven Improvements (Update M Status)

#### Next Coverage Targets (Agreed)

- `PayoutRouter` branch coverage target **>=80%** — **achieved at 87.80%**.
- `GiveVault4626` branch coverage target **75–78%** with optional **80%** stretch — **exceeded at 83.05%**.
- Update M added focused branch closures; both suites consolidated into single files:
  - `test/unit/TestContract06_PayoutRouter.t.sol` — 50 cases covering functional correctness + all branch paths (merged from former TC17)
  - `test/unit/TestContract18_GiveVault4626Branches.t.sol` — 41 cases covering full vault lifecycle + branch paths

#### Completed (High Priority)

- Added dedicated `StorageLib` accessor/revert suite (`test/unit/TestContract20_StorageLib.t.sol`) covering
  `InvalidVault`, `InvalidAdapter`, `InvalidRisk`, `InvalidStrategy`, `InvalidCampaign`,
  `InvalidCampaignVault`, and `InvalidRole` branches.
- Added `CampaignRegistry` branch suite (`test/unit/TestContract19_CampaignRegistryBranches.t.sol`) for
  stake/checkpoint lifecycle: `recordStakeDeposit`, `requestStakeExit`, `finalizeStakeExit`,
  `scheduleCheckpoint`, `updateCheckpointStatus`, `voteOnCheckpoint`, `finalizeCheckpoint`.
- Added explicit UUPS upgrade authorization tests (`test/unit/TestContract21_UUPSUpgradeAuth.t.sol`) for
  `ROLE_UPGRADER` enforcement across selected upgradeable contracts.

#### Completed (Medium Priority)

- Extended `TestContract07_NGORegistry.t.sol` with negative paths (`NoTimelockPending`, invalid NGO
  on propose/emergency set, unauthorized pause/unpause/remove/update).
- Extended `TestContract10_CampaignVaultFactory.t.sol` with deployment fail-leg and zero-address guard tests
  (`initializeCampaign`, registry/router wiring, implementation guards).
- Added `GrowthAdapter` edge-case tests in `test/TestContract05_YieldAdapters.t.sol` for
  `invest(0)`, `setGrowthIndex(<1e18)`, divest cap branch (`normalized > totalDeposits`),
  and zero-return divest behavior.
- Expanded `RiskModule` validation matrix in `TestContract12_ModuleLibraries.t.sol` for threshold/LTV,
  penalty, cap consistency, ID mismatch, and equality-boundary pass cases.

#### Remaining (Fork-Gated but Important)

- Continue `AaveAdapter` and ETH wrapper branch closure in fork/fuzz suites
  (slippage/full-withdraw/revert-path behavior) rather than unit-only targets.

### Optional Depth Work (Not Blockers for Current Scope)

- Add fork block pinning runbook for strict reproducibility
- Add operator-facing PT listing runbook in `README.md`
- Extend reporting around value-accrual assets (wstETH/cbETH) in UI/docs

---

## Test Organization & Standards (Formalized)

### **Test Suite Structure**

Tests are formally organized by scope, intent, and test type:

| Category        | Directory           | Files | Purpose                                            | Example                              | Naming                       |
| --------------- | ------------------- | ----- | -------------------------------------------------- | ------------------------------------ | ---------------------------- |
| **Base**        | `test/base/`        | 3     | Shared deployment fixtures, 3-phase provisioning   | Base01_DeployCore.t.sol              | `Base0{1,2,3}_Deploy*.t.sol` |
| **Unit**        | `test/unit/`        | 20    | Single-contract functionality, property validation | TestContract01_ACLManager.t.sol      | `TestContract{NN}_*.t.sol`   |
| **Integration** | `test/integration/` | 2     | Full workflow cycles, end-to-end scenarios         | TestAction01_CampaignLifecycle.t.sol | `TestAction{NN}_*.t.sol`     |
| **Fork**        | `test/fork/`        | 10    | Live protocol interactions (Aave, Pendle, wstETH)  | ForkTest01_AaveAdapter               | `ForkTest{NN}_*.fork.t.sol`  |
| **Fuzz**        | `test/fuzz/`        | 4     | Stateless/stateful property testing                | FuzzTest03_PayoutRouter              | `FuzzTest{NN}_*.t.sol`       |
| **Invariant**   | `test/invariant/`   | 3     | Multi-step protocol invariants with handlers       | InvariantTest02_PayoutRouter         | `InvariantTest{NN}_*.t.sol`  |

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

| Type            | Count       | Example                                       | Scope                             |
| --------------- | ----------- | --------------------------------------------- | --------------------------------- |
| **Base env**    | 3           | Base01, Base02, Base03                        | Deployment fixtures only          |
| **Unit**        | 407 cases   | 20 files from adapterKinds to UUPSUpgradeAuth | Single-contract, deterministic    |
| **Integration** | ~400+ cases | Campaign lifecycle, multi-strategy ops        | Full workflows, real dependencies |
| **Fork**        | 9 suites    | Aave (USDC/WETH/ETH), Pendle (yoUSD, yoETH, maturity/donor cycle), checkpoint voting, multi-vault | Live mainnet protocols |
| **Fuzz**        | 4 suites    | Router, vault, adapters, registry             | Property-based bounded runs       |
| **Invariant**   | 3 suites    | Router, vault, registry                       | Multi-step invariant handlers     |
| **Total**       | 407         | Unit + integration only                       | Production coverage               |

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

- Fork: `ForkTest01_*` … `ForkTest09_*` (9 suites, sequential)
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
- Pendle fork smoke (`ForkTest10`) uses `PENDLE_BASE_MARKET`, `PENDLE_BASE_PT`, and optionally `PENDLE_BASE_TOKEN_OUT` (defaults to USDC for standard markets; set to yoUSD/yoETH for yield-bearing markets)
- `ForkTest11_PendleYoUSD` and `ForkTest12_PendleYoETH` use hardcoded addresses from `ForkAddresses.sol` — no extra env vars required
- `Deploy02_VaultsAndAdapters.s.sol` reads `PENDLE_TOKEN_OUT_ADDRESS` for the 7th PendleAdapter constructor arg; defaults to `USDC_ADDRESS` when unset (correct for standard PT-aUSDC markets)

### PendleAdapter tokenOut — Market Types

| Market type | Example | `asset_` (invest in) | `tokenOut_` (receive on divest) |
|-------------|---------|---------------------|--------------------------------|
| Standard | PT-aUSDC | USDC | USDC (same) |
| Yield-bearing | PT-yoUSD | USDC | yoUSD (different) |
| Yield-bearing | PT-yoETH | WETH | yoETH (different) |

The SY contract's `getTokensOut()` determines the valid `tokenOut_` values. Passing the wrong token causes `SYInvalidTokenOut` revert. Verify with:
```bash
cast call <SY_ADDRESS> "getTokensOut()(address[])" --rpc-url $BASE_RPC_URL
```
