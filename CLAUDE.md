# GIVE Protocol — Concise Status Summary

Last updated: 2026-02-20

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

### Update A — Phase 0 Bug Fixes (Complete)

Fixed:

- `feeBps` dynamic usage in PayoutRouter
- `_investExcessCash` no longer blocks deposit when invest paused
- `forceClearAdapter` no longer orphans adapter funds

Files:

- `src/payout/PayoutRouter.sol`
- `src/vault/GiveVault4626.sol`

Verify:

- `forge test -v`

### Update B — Baseline Stabilization (Complete)

Fixed CampaignRegistry test actor addresses (precompile collision in test setup).

Files:

- `test/TestContract03_CampaignRegistry.t.sol`

Verify:

- `forge test --match-path test/TestContract03_CampaignRegistry.t.sol -v`
- `forge test -v`

### Update C — Static Analysis Focused Pass (Complete)

Slither priority detectors + Semgrep auto pass triaged.

Artifacts:

- `slither-findings.md`
- `slither-report.json`
- `slither-output.txt`
- `semgrep-report.json`

Commands:

- `slither . --compile-force-framework foundry --filter-paths "lib/,node_modules/" --exclude-dependencies --json slither-report.json`
- `semgrep --config auto src/`

### Update D — PayoutRouter Accumulator Migration (Complete)

Push distribution replaced by pull/accumulator design.

Files:

- `src/payout/PayoutRouter.sol`
- related call sites/tests updated in `test/`

Verify:

- `forge test --match-path test/TestContract06_PayoutRouter.t.sol -v`
- `forge test -v`

### Update E — Vault Re-registration/Stale Preference Handling (Complete)

Implemented stale preference auto-clear and vault reassignment eventing.

Files:

- `src/payout/PayoutRouter.sol`
- related tests in `test/`

Verify:

- `forge test --match-path test/TestContract06_PayoutRouter.t.sol -v`

### Update F — Unit Gap Fill (Complete)

Added missing unit suites:

Files:

- `test/unit/TestContract07_NGORegistry.t.sol`
- `test/unit/TestContract10_CampaignVaultFactory.t.sol`
- `test/unit/TestContract11_AdapterKinds.t.sol`
- `test/unit/TestContract12_ModuleLibraries.t.sol`

Verify:

- `forge test --match-path "test/unit/**" -v`

### Update G — Pendle Integration (Complete)

Implemented real Pendle adapter path and deployment wiring.

Files:

- `src/adapters/kinds/PendleAdapter.sol`
- `test/unit/TestContract13_PendleAdapter.t.sol`
- `test/fork/ForkTest10_PendleAdapter.fork.t.sol`
- `script/Deploy02_VaultsAndAdapters.s.sol`
- `script/Deploy03_Initialize.s.sol`
- `test/base/Base02_DeployVaultsAndAdapters.t.sol`
- `foundry.toml`
- `.gitmodules`

Verify:

- `forge test --match-path test/unit/TestContract13_PendleAdapter.t.sol -v`
- `forge test --match-path test/fork/ForkTest10_PendleAdapter.fork.t.sol -v`
- `forge test --match-path test/integration/TestAction02_MultiStrategyOperations.t.sol -v`

### Update I — Frontend Integration Suite (Complete)

Viem-based smoke test covering the full deposit/redeem lifecycle against
plain Anvil, Base mainnet fork, and live Base RPC. Multi-chain config layer
added for Arbitrum and Optimism extensibility. Deploy03 wiring gap fixed.

Files:

- `script/frontend/viem-smoke.mjs` (new)
- `script/frontend/fork-smoke.sh` (new)
- `script/operations/deploy_local_all.sh` (new)
- `config/chains/base.json` (new)
- `config/chains/arbitrum.json` (new)
- `config/chains/optimism.json` (new)
- `config/chains/local.json` (new)
- `script/Deploy02_VaultsAndAdapters.s.sol` (persist USDCAddress)
- `script/Deploy03_Initialize.s.sol` (wire donationRouter + authorizedCaller)
- `script/base/BaseDeployment.sol` (Arbitrum/Optimism chainId support)

Fixes caught by smoke tests:

- `setDonationRouter` was never called in Deploy03 — PayoutRouter share
  tracking and yield routing were completely bypassed
- `setAuthorizedCaller(vault)` was never called — vault calls into
  PayoutRouter would revert unconditionally
- USDCAddress not persisted to deployment JSON

Verify:

- `npm run frontend:smoke:local`
- `BASE_RPC_URL=... npm run frontend:smoke:rpc`
- `BASE_RPC_URL=... npm run frontend:smoke:fork`

Results: 33/33 local, 32/32 Base fork, 11/11 Base RPC.

### Update J — Coverage Hardening (Complete)

Baseline: 62% lines / 34% branches. Target: >72% lines / >45% branches / >75% functions.

#### Stack-too-deep investigation (resolved — `--ir-minimum` required)

Root cause: OZ's `__ERC20_init` stores name/symbol via inline assembly (`value0` Yul var).
With `optimizer=false, via_ir=false`, this hits the 16-slot EVM stack limit regardless of
how our own code is structured. `--ir-minimum` is the correct and necessary workaround —
not removable without changing OZ internals.

Source changes made:

- `src/payout/PayoutRouter.sol` — `_calculateAllocations` refactored to use `CalcParams`
  struct (reduces stack slots from ~13 to ~8 in that function)
- `src/vault/GiveVault4626.sol` — `initialize` split into `_initParents` +
  `_initRolesAndConfig` private helpers (reduces main function stack depth)

Coverage profile command (unchanged — `--ir-minimum` still required):

```bash
FOUNDRY_PROFILE=coverage forge coverage --ir-minimum --report summary \
  --no-match-path "test/fork/**:test/fuzz/**:test/invariant/**"
```

#### Test additions (all passing)

| Task                             | File                                                   | Cases          | Status |
| -------------------------------- | ------------------------------------------------------ | -------------- | ------ |
| ManualManageAdapter unit suite   | `test/unit/TestContract14_ManualManageAdapter.t.sol`   | 21             | ✓      |
| ClaimableYieldAdapter unit suite | `test/unit/TestContract15_ClaimableYieldAdapter.t.sol` | 13             | ✓      |
| ACLShim unit suite               | `test/unit/TestContract16_ACLShim.t.sol`               | 7              | ✓      |
| PayoutRouter branch gaps         | `test/TestContract06_PayoutRouter.t.sol`               | +10 (28 total) | ✓      |
| GiveVault4626 branch gaps        | `test/TestContract04_VaultSystem.t.sol`                | +8 (17 total)  | ✓      |
| RiskModule/EmergencyModule       | `test/unit/TestContract12_ModuleLibraries.t.sol`       | +4 (8 total)   | ✓      |

Total new test cases added: 63. All 321 unit+integration tests pass.

#### Update J extension — PayoutRouter + GiveVault4626 branch hardening (Complete)

Targeted 51 specific untested branches identified by coverage analysis.

| File                                                   | Cases | Branches hit                                                                                                                                                                                                                                                                                                 |
| ------------------------------------------------------ | ----- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| `test/unit/TestContract17_PayoutRouterBranches.t.sol`  | 17    | `FeeIncreaseTooLarge`, `TimelockNotExpired`, `FeeChangeNotFound`, `VaultReassigned`, `InvalidAllocation`, `InvalidBeneficiary`, `payoutsHalted` (record+claim), `deltaPerShare==0`, `StalePrefCleared`, zero-fee, 75% split, zero-beneficiary full-campaign, no-accrual, acc==debt                           |
| `test/unit/TestContract18_GiveVault4626Branches.t.sol` | 21    | `emergencyPause` blocks deposit, `GracePeriodExpired`, grace-period withdraw allowed, `InvalidAsset`, `InvalidAdapter`, `AdapterHasFunds`, zero-profit harvest, sufficient-cash early-return, `ExcessiveLoss`, `GracePeriodActive`, `InsufficientAllowance`, allowance decrement, all ETH method error paths |

Total tests after extension: 359 passed, 0 failed.

Verify:

- `forge test -v`
- `npm run test:fast` (fast iteration — no fork/fuzz/invariant)
- `npm run coverage:summary`

---

### Update H — Fork Gap Coverage Additions (Complete for GAP-1..5)

Added/validated fork suites:

Files:

- `test/fork/ForkTest04_DepositETH.fork.t.sol` (GAP-1)
- `test/fork/ForkTest03_CompoundingAdapterWstETH.fork.t.sol` (GAP-2)
- `test/fork/ForkTest07_MultiVaultCampaign.fork.t.sol` (GAP-4)
- `test/fork/ForkTest02_CheckpointVoting.fork.t.sol` (GAP-5)
- `test/fork/ForkAddresses.sol`
- `test/fork/ForkBase.t.sol`

Additional hardening from fork feedback:

- `src/adapters/AaveAdapter.sol` (`divest` full-withdraw/slippage accounting)
- fork test tolerance updates in `test/fork/`

Verify:

- `forge test --match-path test/fork/ForkTest04_DepositETH.fork.t.sol -v`
- `forge test --match-path test/fork/ForkTest03_CompoundingAdapterWstETH.fork.t.sol -v`
- `forge test --match-path test/fork/ForkTest07_MultiVaultCampaign.fork.t.sol -v`
- `forge test --match-path test/fork/ForkTest02_CheckpointVoting.fork.t.sol -v`
- `forge test --match-path test/fork/ForkTest01_AaveAdapter.fork.t.sol -v`
- `forge test --match-path test/fork/ForkTest05_ForkSanity.fork.t.sol -v`
- `forge test --match-path test/fork/ForkTest06_GiveVault.fork.t.sol -v`
- `forge test --match-path test/fork/ForkTest09_PayoutRouterGas.fork.t.sol -v`

---

## Pendle PT Listing Policy (Flexible but Gated)

You can add new PT markets, but not arbitrarily.
Each listing must pass:

1. Correct series tuple: `asset` + `market` + `ptToken`
2. Adequate market liquidity for expected size
3. Strategy risk/maturity fit
4. Fork smoke with exact addresses

Fork smoke env:

```bash
PENDLE_BASE_MARKET=<market>
PENDLE_BASE_PT=<ptToken>
forge test --match-path "test/fork/ForkTest10_PendleAdapter.fork.t.sol" -v
```

Deployment env:

```bash
PENDLE_ROUTER_ADDRESS=0x888888888889758F76e7103c6CbF23ABbF58F946
PENDLE_MARKET_ADDRESS=<market>
PENDLE_PT_ADDRESS=<ptToken>
```

Integration smoke:

```bash
forge test --match-path "test/integration/TestAction02_MultiStrategyOperations.t.sol" -v
```

---

## Frontend Integration Flow (Complete Through Phase 5)

### Phase 5 — Done

| Check                                           | Tool              | Status |
| ----------------------------------------------- | ----------------- | ------ |
| Local lifecycle (approve → deposit → redeem)    | viem + Anvil      | ✓      |
| PayoutRouter share tracking after deposit       | viem + Anvil      | ✓      |
| ERC-4626 conversion parity                      | viem + Anvil      | ✓      |
| Revert selector mapping                         | viem + Anvil      | ✓      |
| Event log queries                               | viem + Anvil      | ✓      |
| Live Base RPC protocol connectivity             | viem --mode=rpc   | ✓      |
| USDC, Aave, wstETH, Pendle on Base              | viem --mode=rpc   | ✓      |
| Base fork full lifecycle against real USDC/Aave | viem + fork Anvil | ✓      |
| Multi-chain config layer (Arbitrum, Optimism)   | config/chains/    | ✓      |

Run:

```bash
npm run frontend:smoke:local
BASE_RPC_URL=... npm run frontend:smoke:rpc
BASE_RPC_URL=... npm run frontend:smoke:fork
```

---

## Phase 6 — Tenderly + Production Readiness (Pending)

Phase 6 covers everything between "fork smoke passes" and "safe to deploy to mainnet".
None of this is covered by any prior phase.

### 6A — Tenderly Virtual TestNet scenarios

Deploy to a Tenderly Virtual TestNet (simulated Base mainnet with real state) and
run scripted scenarios. This is the final pre-deploy gate in the mandatory deployment
gates list.

Scenarios required:

- **Happy path**: deposit → yield accrual → harvest → claimYield → redeem
- **Emergency recovery**: emergencyPause → grace period → emergencyWithdrawUser
- **Checkpoint halt/resume**: scheduleCheckpoint → voteOnCheckpoint → finalizeCheckpoint
- **Fee timelock**: proposeFeeChange → wait 7 days → executeFeeChange
- **Gas profile**: export gas traces for deposit, harvest, claimYield, redeem

Collect: trace links, gas evidence, event shapes — needed for release signoff.

### 6B — Multi-RPC fallback validation

The smoke test currently skips fallback when only one RPC is provided.
Needs a second endpoint (`BASE_RPC_URL_FALLBACK`) configured and validated:

- Primary RPC degraded → fallback kicks in transparently
- Both RPCs down → surfaced error is user-friendly, not a raw viem transport error

### 6C — Revert message UX audit

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

### 6D — Mainnet deployment runbook

The forge scripts exist but the actual mainnet deployment process isn't documented
or rehearsed. Before going live:

- Private key management (hardware wallet or KMS — no plaintext `PRIVATE_KEY`)
- Exact deploy sequence with verification flags
- Post-deploy checklist: verify contracts on Basescan, confirm donationRouter wired,
  confirm authorizedCaller set, smoke test against deployed addresses
- Owner handoff: transfer admin roles from deployer to multisig

### 6E — Contract verification on Basescan

`VERIFY_CONTRACTS=true` path in `BaseDeployment.verifyContract()` exists but is
untested. Validate that all proxies and implementations verify correctly:

```bash
VERIFY_CONTRACTS=true ETHERSCAN_API_KEY=... forge script script/Deploy01_Infrastructure.s.sol \
  --rpc-url $BASE_RPC_URL --broadcast --verify
```

### 6F (Lower Priority) — GAP-6 adapter fork suites

No dedicated fork suites yet for `GrowthAdapter`, `ClaimableYieldAdapter`,
`ManualManageAdapter`. Not a blocker — no live Base deployment target for
realistic fork behavior. Add when adapters have mainnet deployments to fork against.

---

## Pending / Future Improvements (Only Uncovered Items)

### Coverage-Driven Improvements (Update M Status)

#### Next Coverage Targets (Agreed)

- `PayoutRouter` branch coverage target **>=80%** — **achieved at 87.80%**.
- `GiveVault4626` branch coverage target **75–78%** with optional **80%** stretch — **exceeded at 83.05%**.
- Update M added focused branch closures in:
  - `test/unit/TestContract17_PayoutRouterBranches.t.sol` (expanded)
  - `test/unit/TestContract18_GiveVault4626Branches.t.sol` (expanded)

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

| Category        | Directory           | Files | Purpose                                                 | Example                              | Naming                       |
| --------------- | ------------------- | ----- | ------------------------------------------------------- | ------------------------------------ | ---------------------------- |
| **Base**        | `test/base/`        | 3     | Shared deployment fixtures, 3-phase provisioning        | Base01_DeployCore.t.sol              | `Base0{1,2,3}_Deploy*.t.sol` |
| **Unit**        | `test/unit/`        | 21    | Single-contract functionality, property validation      | TestContract07_NGORegistry.t.sol     | `TestContract{NN}_*.t.sol`   |
| **Integration** | `test/integration/` | 2     | Full workflow cycles, end-to-end scenarios              | TestAction01_CampaignLifecycle.t.sol | `TestAction{NN}_*.t.sol`     |
| **Fork**        | `test/fork/`        | 10    | Live protocol interactions (Aave, Pendle, wstETH)       | ForkTest01_AaveAdapter               | `ForkTest{NN}_*.fork.t.sol`  |
| **Fuzz**        | `test/fuzz/`        | 4     | Stateless/stateful property testing                     | FuzzTest03_PayoutRouter              | `FuzzTest{NN}_*.t.sol`       |
| **Invariant**   | `test/invariant/`   | 3     | Multi-step protocol invariants with handlers            | InvariantTest02_PayoutRouter         | `InvariantTest{NN}_*.t.sol`  |
| **Root**        | `test/`             | 9     | Legacy integration tests (being consolidated into unit) | TestContract01_ACLManager.t.sol      | `TestContract{NN}_*.t.sol`   |

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
| **Unit**        | ~400+ cases | 21 files from adapterKinds to UUPSUpgradeAuth | Single-contract, deterministic    |
| **Integration** | ~400+ cases | Campaign lifecycle, multi-strategy ops        | Full workflows, real dependencies |
| **Fork**        | 10 suites   | Aave, Pendle, wstETH, checkpoint voting       | Live mainnet protocols            |
| **Fuzz**        | 4 suites    | Router, vault, adapters, registry             | Property-based bounded runs       |
| **Invariant**   | 3 suites    | Router, vault, registry                       | Multi-step invariant handlers     |
| **Total**       | 428+        | Unit + integration only                       | Production coverage               |

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

- Fork: `ForkTest01_*` … `ForkTest10_*`
- Fuzz: `FuzzTest01_*` … `FuzzTest04_*`
- Invariant: `InvariantTest01_*` … `InvariantTest03_*`

Validation:

- File names, contract declarations, and NatSpec `@title` fields are synchronized.
- Latest default run (`forge test`) remains green: 428 passed, 0 failed, 0 skipped.

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
- Pendle fork smoke uses `PENDLE_BASE_MARKET` and `PENDLE_BASE_PT`
