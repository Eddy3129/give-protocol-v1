# GIVE Protocol — Foundry Test Suite

Last updated: 2026-02-21

## Overview

The GIVE Protocol test suite contains **428 passing tests** across **44 Solidity test files** (~14,000 lines).
Tests are organized into six categories: base fixtures, unit, integration, fork, fuzz, and invariant.

Coverage is measured on unit + integration only (fork/fuzz/invariant are validation layers, not coverage contributors).

| Metric     | Overall | PayoutRouter | GiveVault4626 |
|------------|---------|--------------|---------------|
| Lines      | 60.43%  | 88.72%       | 78.79%        |
| Statements | 61.00%  | 88.85%       | 81.07%        |
| Branches   | 49.23%  | 87.80%       | 83.05%        |
| Functions  | 62.62%  | 88.10%       | 71.70%        |

---

## Directory Structure

```
test/
├── base/                          # Shared deployment fixtures (3 files)
│   ├── Base01_DeployCore.t.sol
│   ├── Base02_DeployVaultsAndAdapters.t.sol
│   └── Base03_DeployComprehensiveEnvironment.t.sol
├── unit/                          # Single-contract functionality (21 files)
│   ├── TestContract01_ACLManager.t.sol
│   ├── TestContract02_StrategyRegistry.t.sol
│   ├── TestContract03_CampaignRegistry.t.sol
│   ├── TestContract04_VaultSystem.t.sol
│   ├── TestContract05_YieldAdapters.t.sol
│   ├── TestContract06_PayoutRouter.t.sol
│   ├── TestContract07_NGORegistry.t.sol
│   ├── TestContract08_GiveProtocolCore.t.sol
│   ├── TestContract09_StrategyManager.t.sol
│   ├── TestContract10_CampaignVaultFactory.t.sol
│   ├── TestContract11_AdapterKinds.t.sol
│   ├── TestContract12_ModuleLibraries.t.sol
│   ├── TestContract13_PendleAdapter.t.sol
│   ├── TestContract14_ManualManageAdapter.t.sol
│   ├── TestContract15_ClaimableYieldAdapter.t.sol
│   ├── TestContract16_ACLShim.t.sol
│   ├── TestContract17_PayoutRouterBranches.t.sol
│   ├── TestContract18_GiveVault4626Branches.t.sol
│   ├── TestContract19_CampaignRegistryBranches.t.sol
│   ├── TestContract20_StorageLib.t.sol
│   └── TestContract21_UUPSUpgradeAuth.t.sol
├── integration/                   # Full workflow cycles (2 files)
│   ├── TestAction01_CampaignLifecycle.t.sol
│   └── TestAction02_MultiStrategyOperations.t.sol
├── fork/                          # Live protocol interactions (11 files)
│   ├── ForkBase.t.sol
│   ├── ForkTest01_AaveAdapter.fork.t.sol
│   ├── ForkTest02_CheckpointVoting.fork.t.sol
│   ├── ForkTest03_CompoundingAdapterWstETH.fork.t.sol
│   ├── ForkTest04_DepositETH.fork.t.sol
│   ├── ForkTest05_ForkSanity.fork.t.sol
│   ├── ForkTest06_GiveVault.fork.t.sol
│   ├── ForkTest07_MultiVaultCampaign.fork.t.sol
│   ├── ForkTest08_PTAdapterPendleBlocker.fork.t.sol
│   ├── ForkTest09_PayoutRouterGas.fork.t.sol
│   └── ForkTest10_PendleAdapter.fork.t.sol
├── fuzz/                          # Property-based testing (4 files)
│   ├── FuzzTest01_AaveAdapter.t.sol
│   ├── FuzzTest02_CampaignRegistry.t.sol
│   ├── FuzzTest03_PayoutRouter.t.sol
│   └── FuzzTest04_Vault.t.sol
├── invariant/                     # Multi-step invariant suites (3 files)
│   ├── InvariantTest01_CampaignRegistry.t.sol
│   ├── InvariantTest02_PayoutRouter.t.sol
│   └── InvariantTest03_Vault.t.sol
```

---

## Foundry Profiles

Defined in `foundry.toml`. Pass with `FOUNDRY_PROFILE=<name>`.

| Profile     | Purpose                                      | Test Scope                        | Optimizer |
|-------------|----------------------------------------------|-----------------------------------|-----------|
| `default`   | Standard unit + integration run              | Excludes fork, fuzz, invariant    | via_ir    |
| `full`      | Complete validation (all test types)         | All tests                         | via_ir    |
| `fork`      | Live protocol integration                    | `test/fork/**` only               | via_ir    |
| `fuzz`      | Property-based testing (10,000 runs)         | `test/fuzz/**` only               | via_ir    |
| `invariant` | Multi-step invariant checks (256 runs/500d)  | `test/invariant/**` only          | via_ir    |
| `dev-fast`  | Rapid iteration (skips slow suites)          | Excludes fork, fuzz, invariant    | 1 run     |
| `coverage`  | Coverage measurement                         | Unit + integration (no via_ir)    | disabled  |
| `production`| Mainnet-ready build                          | Build only, 2M optimizer runs     | via_ir    |

---

## Base Fixtures

Base fixtures are shared deployment helpers inherited by all other test suites.
They do not contain test cases themselves.

### Base01_DeployCore.t.sol

Deploys core protocol infrastructure:

- `ACLManager` — role-based access control (UUPS proxy)
- `GiveProtocolCore` — protocol orchestration layer (UUPS proxy)
- `StrategyRegistry` — strategy lifecycle management (UUPS proxy)
- `CampaignRegistry` — campaign governance (UUPS proxy)
- `NGORegistry` — NGO identity and KYC (UUPS proxy)
- `PayoutRouter` — yield distribution accumulator (UUPS proxy)

### Base02_DeployVaultsAndAdapters.t.sol

Extends Base01 with vault and adapter infrastructure:

- `GiveVault4626` — ERC-4626 donor vault deployment
- All adapter implementations: Aave, wstETH Compounding, Pendle PT, GrowthAdapter, ClaimableYield, ManualManage
- `CampaignVaultFactory` — proxy factory for campaign-specific vaults
- Strategy registration and adapter linkage

### Base03_DeployComprehensiveEnvironment.t.sol

Extends Base02 with a fully provisioned protocol environment:

- Multiple campaigns submitted and approved
- Multiple NGOs registered and KYC'd
- Multiple vaults deployed and linked to campaigns
- Funding provisioned (test USDC balances, approvals)
- All modules wired and roles assigned

---

## Unit Tests

Unit tests cover individual contracts in isolation with deterministic inputs.

### TestContract01_ACLManager.t.sol (root)

**Scope**: Role-based access control and admin management

| Test Area | Coverage |
|-----------|----------|
| All 8 canonical protocol roles (ROLE_ADMIN, ROLE_UPGRADER, ROLE_OPERATOR, ROLE_ORACLE, ROLE_EMERGENCY, ROLE_PAUSER, ROLE_CAMPAIGN_MANAGER, ROLE_STRATEGY_MANAGER) | Grant/revoke/check |
| Dynamic role creation and querying | Full lifecycle |
| Two-step admin transfer | Propose → accept |
| UUPS upgradeability with ROLE_UPGRADER | Auth guard |
| Unauthorized upgrade attempts | Revert paths |

### TestContract02_StrategyRegistry.t.sol (root)

**Scope**: Strategy lifecycle and vault linking

| Test Area | Coverage |
|-----------|----------|
| Strategy registration with metadata | Register → query |
| Status transitions: PENDING → ACTIVE → DEPRECATED | All valid paths |
| Invalid transitions (e.g., DEPRECATED → ACTIVE) | Revert paths |
| Vault-to-strategy linking | Link, unlink |
| Access control on admin operations | ROLE_STRATEGY_MANAGER |

### TestContract03_CampaignRegistry.t.sol (root)

**Scope**: Campaign lifecycle and H-01 security fix

| Test Area | Coverage |
|-----------|----------|
| Campaign submission and approval workflow | Full lifecycle |
| H-01 fix: deposit refund on rejection | Before/after |
| H-01 fix: stake slash on bad actor | Slash logic |
| Stake deposit and exit lifecycle | requestStakeExit → finalizeStakeExit |
| Checkpoint scheduling and voting | scheduleCheckpoint → voteOnCheckpoint → finalize |

### TestContract04_VaultSystem.t.sol (root)

**Scope**: Vault storage isolation and UUPS migration fixes

| Test Area | Coverage |
|-----------|----------|
| C-01 fix: storage collision between vault instances | Isolation proof |
| M-01 fix: UUPS upgrade path integrity | Upgrade → verify state |
| Proxy-based vault deployment | Factory pattern |
| Independent state per vault instance | Cross-vault isolation |

### TestContract05_YieldAdapters.t.sol (root)

**Scope**: All yield adapter implementations

| Adapter | Tests |
|---------|-------|
| `GrowthAdapter` | invest(0) edge, setGrowthIndex(<1e18), divest cap (normalized > totalDeposits), zero-return divest |
| `CompoundingAdapter` | invest, divest, yield accrual simulation |
| `PTAdapter` (Pendle) | invest, maturity handling, divest with slippage |
| `ClaimableYieldAdapter` | claim, invest, divest lifecycle |
| `ManualManageAdapter` | manual asset override, invest/divest passthrough |

### TestContract06_PayoutRouter.t.sol (root)

**Scope**: PayoutRouter with mock dependencies

| Test Area | Coverage |
|-----------|----------|
| Accumulator model: delta-per-share calculation | Monotonic invariant |
| Fee timelock enforcement (3-day delay) | Propose → enforce |
| Vault reassignment workflow | Old vault → new vault |
| Preferences: fee override per campaign | Set/get/clear |
| Yield recording from authorized callers | recordYield() |
| Allocation tracking and claiming | allocate → claim |

### TestContract07_NGORegistry.t.sol (unit/)

**Scope**: NGO management, negative paths

| Test Area | Coverage |
|-----------|----------|
| NGO registration and metadata updates | Full lifecycle |
| KYC hash storage and verification | Store → verify |
| Approval workflow | Pending → approved |
| Unauthorized pause/unpause/remove/update | All revert paths |
| `NoTimelockPending` error condition | Error branch |
| Invalid NGO address on propose/emergency set | Zero-address guard |

### TestContract08_GiveProtocolCore.t.sol (root)

**Scope**: Protocol orchestration and module delegation

| Test Area | Coverage |
|-----------|----------|
| Module registration and delegation | Register → delegate |
| Delegated calls to registered modules | Proxy pattern |
| Access control on module management | ROLE_OPERATOR |
| UUPS upgradeability | Auth guard |
| Unauthorized module calls | Revert paths |

### TestContract09_StrategyManager.t.sol (root)

**Scope**: Strategy manager with mock dependencies

| Test Area | Coverage |
|-----------|----------|
| Strategy allocation to vaults | Allocate → verify |
| Rebalancing logic | Over/under allocation |
| Mock vault and strategy utility functions | Internal helpers |
| Access control on rebalance operations | ROLE_STRATEGY_MANAGER |

### TestContract10_CampaignVaultFactory.t.sol (unit/)

**Scope**: Vault factory deployment and guards

| Test Area | Coverage |
|-----------|----------|
| Successful campaign vault deployment | Happy path |
| Registry wiring: vault ↔ campaign linkage | Post-deploy assertions |
| Router wiring: vault ↔ PayoutRouter linkage | Post-deploy assertions |
| Zero-address guards on registry/router | Revert paths |
| Implementation address guards | Zero impl guard |
| `initializeCampaign` fail paths | Revert on bad params |
| Deployment fail leg (factory error handling) | Error propagation |

### TestContract11_AdapterKinds.t.sol (unit/)

**Scope**: Adapter type classification

| Test Area | Coverage |
|-----------|----------|
| All adapter kind enum values | AAVE, COMPOUND, PENDLE, GROWTH, CLAIMABLE, MANUAL |
| Kind-to-adapter mapping | Correct classification |
| Kind registry lookups | Query by kind |

### TestContract12_ModuleLibraries.t.sol (unit/)

**Scope**: RiskModule validation matrix

| Test Area | Coverage |
|-----------|----------|
| Threshold/LTV validation | Valid ranges, boundary pass |
| Penalty calculation | Formula correctness |
| Cap consistency checks | Over/under cap |
| ID mismatch detection | Error condition |
| Equality boundary pass cases | Edge boundaries |
| Invalid threshold combinations | Revert paths |

### TestContract13_PendleAdapter.t.sol (unit/)

**Scope**: Pendle PT adapter unit behavior

| Test Area | Coverage |
|-----------|----------|
| invest() with valid PT market | Asset → PT exchange |
| divest() before maturity | PT → asset exchange |
| Maturity handling | Post-maturity divest path |
| Slippage tolerance enforcement | Exceeds tolerance → revert |
| Mock Pendle router interactions | Stub calls |

### TestContract14_ManualManageAdapter.t.sol (unit/)

**Scope**: Manual asset management adapter

| Test Area | Coverage |
|-----------|----------|
| invest() passthrough behavior | Asset delegation |
| divest() passthrough behavior | Asset recovery |
| Manual override: setManagedAmount() | Override logic |
| Access control on overrides | Authorized caller |
| Zero-amount invest/divest | Edge cases |

### TestContract15_ClaimableYieldAdapter.t.sol (unit/)

**Scope**: Claimable yield adapter

| Test Area | Coverage |
|-----------|----------|
| invest() with yield token tracking | Deposit → track |
| claim() yield accumulation | Claim → record |
| divest() with accrued yield | Yield included in divest |
| Unauthorized claim attempts | Revert paths |
| Zero-yield claim | Edge case |

### TestContract16_ACLShim.t.sol (unit/)

**Scope**: ACL shim access enforcement

| Test Area | Coverage |
|-----------|----------|
| Shim layer grants correct role checks | Role delegation |
| Unauthorized access through shim | Revert paths |
| Role inheritance through shim | Parent role resolution |

### TestContract17_PayoutRouterBranches.t.sol (unit/)

**Scope**: PayoutRouter branch coverage (87.80% branches)

| Branch Cluster | Tests |
|----------------|-------|
| Fee changes | Propose fee, enforce after timelock, reject premature enforcement |
| Vault reassignment | Reassign mid-cycle, accumulator continuity |
| Preferences | Set campaign fee override, read override, clear override |
| Yield recording | Record from authorized, reject unauthorized |
| Allocation | Allocate shares, partial claim, full claim |
| Accrual | recordYield with multiple campaigns, zero yield |
| Error conditions | All revert selectors mapped |

### TestContract18_GiveVault4626Branches.t.sol (unit/)

**Scope**: GiveVault4626 branch coverage (83.05% branches)

| Branch Cluster | Tests |
|----------------|-------|
| Pause paths | pause(), unpause(), deposit-while-paused revert |
| Grace period | setGracePeriod(), post-grace revert, GracePeriodExpired |
| Adapter management | setAdapter(), unset, zero-address guard |
| Harvest | harvest() with yield, harvest() with zero yield, unauthorized harvest |
| Cash shortfall | deposit exceeds available cash, partial fill |
| Emergency withdrawal | emergencyWithdraw(), from pause state |
| ETH deposits | ETH-denominated vault path |
| Slippage | ExcessiveLoss on high slippage redeem |

### TestContract19_CampaignRegistryBranches.t.sol (unit/)

**Scope**: CampaignRegistry branch coverage

| Branch Cluster | Tests |
|----------------|-------|
| `recordStakeDeposit` | Valid, zero-amount, unauthorized |
| `requestStakeExit` | Valid, double-request, not-staked |
| `finalizeStakeExit` | Before/after cooldown, unauthorized |
| `scheduleCheckpoint` | Valid, already-scheduled, unauthorized |
| `updateCheckpointStatus` | All valid transitions |
| `voteOnCheckpoint` | For/against/abstain, double-vote |
| `finalizeCheckpoint` | Quorum met, quorum not met, early finalize |

### TestContract20_StorageLib.t.sol (unit/)

**Scope**: StorageLib accessor and revert conditions

| Revert | Trigger |
|--------|---------|
| `InvalidVault` | Non-existent vault lookup |
| `InvalidAdapter` | Non-existent adapter lookup |
| `InvalidRisk` | Non-existent risk module lookup |
| `InvalidStrategy` | Non-existent strategy lookup |
| `InvalidCampaign` | Non-existent campaign lookup |
| `InvalidCampaignVault` | Non-existent campaign-vault pair lookup |
| `InvalidRole` | Non-existent role lookup |

### TestContract21_UUPSUpgradeAuth.t.sol (unit/)

**Scope**: UUPS upgrade authorization across contracts

| Contract | Test |
|----------|------|
| ACLManager | Only ROLE_UPGRADER can upgrade |
| GiveProtocolCore | Only ROLE_UPGRADER can upgrade |
| PayoutRouter | Only ROLE_UPGRADER can upgrade |
| CampaignRegistry | Only ROLE_UPGRADER can upgrade |
| NGORegistry | Only ROLE_UPGRADER can upgrade |
| Unauthorized callers | All revert with correct selector |

---

## Integration Tests

Integration tests exercise complete multi-contract workflows using Base03's fully provisioned environment.

### TestAction01_CampaignLifecycle.t.sol

**Scope**: End-to-end campaign from submission to payout

Workflow sequence:

1. Submit campaign via `CampaignRegistry.submitCampaign()`
2. Approve campaign via `CampaignRegistry.approveCampaign()`
3. Deploy vault via `CampaignVaultFactory.deployCampaignVault()`
4. Donor approves USDC and deposits into vault
5. Strategy allocates vault assets to Aave adapter
6. Time-advance simulates yield accrual
7. `harvest()` processes yield through adapter
8. `PayoutRouter.recordYield()` routes yield to accumulator
9. NGO claims payout via `PayoutRouter.claim()`
10. Donor redeems shares and receives principal

**Assertions at each step**: share accounting, accumulator deltas, event emissions, balance changes.

### TestAction02_MultiStrategyOperations.t.sol

**Scope**: Multi-strategy and multi-vault orchestration

Workflow includes:

- Deploy multiple vaults for the same campaign
- Assign different strategies (Aave vs. Growth) per vault
- Parallel yield accrual across vaults
- Aggregated PayoutRouter accumulator behavior
- Strategy rebalancing (over/under-allocation)
- Vault migration: move assets from old to new strategy
- Cross-vault share dilution checks

---

## Fork Tests

Fork tests run against live Base mainnet state pinned at a specific block.
All fork tests require `BASE_RPC_URL` to be set.

**Base fixture** (`ForkBase.t.sol`): Shared setup providing:
- Chain ID validation (Base = 8453)
- Public fallback RPC if `BASE_RPC_URL` not set
- Live contract address resolution
- Block state assertions

### ForkTest01_AaveAdapter.fork.t.sol

**Live protocol**: Aave V3 on Base mainnet

| Test | What It Validates |
|------|-------------------|
| `invest()` with live USDC | Correct aToken minting |
| aToken balance after invest | Matches invested amount ±slippage |
| 30-day yield accrual (time-warped) | Positive yield generated |
| Profit withdrawal via `divest()` | USDC recovered > deposited |
| Partial divest | Proportional aToken burn |

### ForkTest02_CheckpointVoting.fork.t.sol

**Live protocol**: CampaignRegistry + NGORegistry on Base fork

| Test | What It Validates |
|------|-------------------|
| Checkpoint scheduling | Valid block range |
| Stakeholder vote recording | For/against/abstain |
| Quorum calculation | Meets threshold |
| Checkpoint finalization | Status transition |
| Payout gating on failed checkpoint | Halted payout |

### ForkTest03_CompoundingAdapterWstETH.fork.t.sol

**Live protocol**: wstETH token on Base mainnet

| Test | What It Validates |
|------|-------------------|
| wstETH invest flow | ETH → stETH → wstETH path |
| Compounding index update | Index increases over time |
| divest with accrued index | More ETH recovered than deposited |
| Oracle price validation | wstETH/ETH rate within bounds |

### ForkTest04_DepositETH.fork.t.sol

**Live protocol**: ETH-native vault on Base fork

| Test | What It Validates |
|------|-------------------|
| ETH deposit to vault | Correct share minting |
| WETH wrapping transparency | Depositor sees native ETH |
| Redeem ETH from vault | Shares → ETH |

### ForkTest05_ForkSanity.fork.t.sol

**Purpose**: Validates fork connectivity and block state

| Check | Expected |
|-------|----------|
| Chain ID | 8453 (Base) |
| Block number | > 0 and reasonable |
| USDC contract exists | Code at address |
| Aave pool exists | Code at address |
| Current block timestamp | Recent |

### ForkTest06_GiveVault.fork.t.sol

**Live protocol**: Full vault lifecycle against Aave V3

| Test | What It Validates |
|------|-------------------|
| Deploy vault on Base fork | Correct initialization |
| Deposit USDC into vault | ERC-4626 share minting |
| Allocate to Aave adapter | aToken received |
| Fast-forward 30 days | Block timestamp advance |
| harvest() yield | Positive yield recorded |
| PayoutRouter receives yield | Accumulator updated |
| Redeem shares | Principal returned ±dust |

### ForkTest07_MultiVaultCampaign.fork.t.sol

**Live protocol**: Multiple vaults per campaign

| Test | What It Validates |
|------|-------------------|
| Two vaults for same campaign | Isolated accounting |
| Parallel deposits into both vaults | Independent share accounting |
| Independent yield accrual | No cross-contamination |
| Aggregated payout via PayoutRouter | Combined accumulator |

### ForkTest08_PTAdapterPendleBlocker.fork.t.sol

**Purpose**: Evidence collection for Pendle PT adapter behavior

| Test | What It Validates |
|------|-------------------|
| PT market lookup | Valid market address |
| PT token balance after invest | Correct PT minting |
| Pre-maturity divest | PT → underlying |
| Slippage evidence | Records actual slippage |

### ForkTest09_PayoutRouterGas.fork.t.sol

**Purpose**: Gas profiling for accumulator model at scale

| Scenario | Gas Measured |
|----------|--------------|
| `recordYield()` with 1 vault | Baseline gas |
| `recordYield()` with 10 vaults | Linear vs. constant scaling |
| `claim()` single NGO | Claim gas |
| `claim()` 50 NGOs batch | Batch gas profile |

**Gas budget assertions**: All operations must stay within defined ceilings.

### ForkTest10_PendleAdapter.fork.t.sol

**Live protocol**: Pendle Protocol PT adapter on Base fork

| Test | What It Validates |
|------|-------------------|
| invest() USDC → PT | PT minting via Pendle router |
| PT balance assertions | Correct amount ±slippage |
| divest() before maturity | PT → USDC via Pendle |
| Full lifecycle timing | Invest → accrue → divest |

---

## Fuzz Tests

Fuzz tests run property-based checks with randomized inputs. Default: 10,000 runs with seed `0x1337`.

### FuzzTest01_AaveAdapter.t.sol

**Properties tested**:
- `invest(amount)` always produces aTokens when `amount > 0`
- `divest(amount)` always returns underlying ≥ 0
- Invest then full divest returns ≥ invested (no principal loss)
- `invest(0)` reverts with `ZeroAmount`
- No integer overflow for any valid `uint256` input bounded by max supply

**Bounds**: `[1, 1e12]` USDC (avoids dust and supply cap)

### FuzzTest02_CampaignRegistry.t.sol

**Properties tested**:
- `submitCampaign()` with any valid metadata never corrupts registry state
- Campaign ID sequence is strictly monotonic
- `approveCampaign(id)` for any approved campaign is idempotent
- Stake deposits with any amount ≤ balance always succeed
- `requestStakeExit()` after `recordStakeDeposit()` always sets exit timestamp

**Bounds**: Fuzzed on campaign name length, stake amount, timestamp offsets

### FuzzTest03_PayoutRouter.t.sol

**Properties tested**:
- `deltaPerShare` is strictly monotonically non-decreasing across any yield recording sequence
- Fee enforcement: effective fee ≤ declared fee cap for any input
- `claim()` never transfers more than `accumulatedYield[ngo]`
- Total claimed across all NGOs never exceeds total yield recorded
- `recordYield(0)` is a no-op (no state change)

**Bounds**: Yield amounts `[1, 1e18]`, fee BPS `[0, 2000]`, share counts `[1, 1e24]`

### FuzzTest04_Vault.t.sol

**Properties tested** (stateful fuzzing):
- `deposit(assets)` followed by `redeem(shares)` returns ≥ assets deposited (no principal loss)
- `convertToShares(assets)` and `convertToAssets(shares)` are inverse operations
- Total assets = sum of all depositor claims (conservation)
- `maxRedeem(user)` is always ≤ user share balance
- Paused vault rejects deposit and redeem

**Stateful handler sequence**: deposit → transfer → redeem → harvest, in arbitrary order

---

## Invariant Tests

Invariant tests run handler sequences in arbitrary order to find property violations.
Default: 256 runs, depth 500, `fail_on_revert = false`.

### InvariantTest01_CampaignRegistry.t.sol

**Invariants**:

| Property | Description |
|----------|-------------|
| `stakeDeposit_zeros_on_decision` | After approval or rejection, stake deposit amount = 0 |
| `totalStaked_consistency` | Sum of all stake positions = totalStaked storage variable |
| `payoutsHalted_requires_checkpoint` | If `payoutsHalted[campaign]`, a failed checkpoint exists |
| `stakePositionSums` | Sum of individual staker balances = total stake per campaign |

**Handlers**: submitCampaign, recordStakeDeposit, requestStakeExit, finalizeStakeExit, approveCampaign, rejectCampaign

### InvariantTest02_PayoutRouter.t.sol

**Invariants**:

| Property | Description |
|----------|-------------|
| `deltaPerShare_monotonic` | `deltaPerShare` never decreases between yield recordings |
| `totalClaimed_le_totalRecorded` | Σ claims ≤ Σ yield recorded |
| `noOverpayment` | Individual NGO claim ≤ their accumulated yield |
| `accumulatorConsistency` | `accumulatedYield[ngo]` = Σ(deltaPerShare × shares) at each checkpoint |

**Handlers**: recordYield, claim, setVaultShares, setFee

### InvariantTest03_Vault.t.sol

**Invariants** (ERC-4626 accounting):

| Property | Description |
|----------|-------------|
| `conversionParity` | `convertToAssets(convertToShares(x)) ≈ x` within rounding |
| `shareConservation` | totalSupply = Σ all user share balances |
| `assetConsistency` | totalAssets ≥ totalSupply × pricePerShare |
| `noFreeShares` | Minting shares without depositing assets is impossible |

**Handlers**: deposit, redeem, transfer, harvest, setAdapter

---

## File Header Convention

All test files use this NatSpec format:

```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title   FuzzTest03_PayoutRouter
 * @author  GIVE Labs
 * @notice  Stateless property-based fuzzing for PayoutRouter accumulator
 * @dev     - Fee enforcement: effective fee ≤ cap for any input
 *          - deltaPerShare is strictly monotonically non-decreasing
 *          - Total claimed ≤ total yield recorded
 *          - recordYield(0) is a no-op
 */
```

---

## Running Tests

See `Makefile` for all targets. Key commands:

```bash
# Standard run (unit + integration, fast)
make test

# Full suite (includes fork, fuzz, invariant)
make test-full

# Specific suites
make test-unit
make test-integration
make test-fork
make test-fuzz
make test-invariant

# Coverage report
make coverage

# With gas report
make test-gas

# Single test file
make test-match MATCH=ForkTest06
```

---

## Environment Variables

| Variable         | Required For   | Description |
|------------------|----------------|-------------|
| `BASE_RPC_URL`   | Fork tests     | Base mainnet or fork RPC endpoint |
| `PENDLE_BASE_MARKET` | ForkTest10 | Pendle market address on Base |
| `PENDLE_BASE_PT` | ForkTest10     | Pendle PT token address on Base |
| `ARBITRUM_RPC_URL` | Multi-chain  | Arbitrum fork endpoint |
| `OPTIMISM_RPC_URL` | Multi-chain  | Optimism fork endpoint |
