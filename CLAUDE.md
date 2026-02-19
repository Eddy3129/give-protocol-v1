# GIVE Protocol — Project Instructions

## Project Overview

No-loss donation protocol built on ERC-4626 vaults. Donors deposit assets (USDC, DAI, WETH),
yield is generated via pluggable adapters (Aave V3, Compound, etc.), and that yield is routed to
campaigns and NGOs via the PayoutRouter. Principal is always fully redeemable.

**Stack:** Solidity 0.8.34, Foundry, OpenZeppelin v5, UUPS proxies, Diamond Storage.

---

## Known Bugs — Fix Before Testing

These must be resolved before the test suite produces meaningful results (RESOLVED):

1. **`feeBps` dead variable** — `PayoutRouter._calculateAllocations` uses the constant
   `PROTOCOL_FEE_BPS = 250` instead of the mutable `s.feeBps`. The entire fee timelock
   mechanism is inert. Fix: replace `PROTOCOL_FEE_BPS` with `s.feeBps` in
   `src/payout/PayoutRouter.sol:476`.

2. **`_investExcessCash` blocks deposits when `investPaused`** — The modifier
   `whenInvestNotPaused` on `_investExcessCash` causes user `deposit()` calls to revert
   whenever invest is paused. Fix: remove the modifier and use an early-return guard instead
   (`if (_vaultConfig().investPaused) return;`) in `src/vault/GiveVault4626.sol:495`.

3. **`forceClearAdapter` orphans funds** — Clears the adapter pointer without calling
   `divest()`, silently dropping those assets from `totalAssets()`. Fix: require adapter holds
   zero assets before clearing, or call `divest(type(uint256).max)` first in
   `src/vault/GiveVault4626.sol:316`.

---

## Mainnet Readiness Plan (Updated 2026-02-19)

Work through phases in order. Do not skip ahead. Mainnet deployment is blocked until all
mandatory gates are green.

### Current Status Snapshot

- ✅ Phase 0 bug fixes are implemented in code:
  - `feeBps` dynamic usage in `PayoutRouter`
  - `_investExcessCash` early-return on `investPaused`
  - `forceClearAdapter` checks adapter has zero assets
- ✅ Phase 0A baseline is green: `forge test -v` passes with 224/224 tests.
- ✅ CampaignRegistry deposit refund path failure fixed in tests by moving actor
  addresses away from precompile range (e.g. `proposer` no longer `address(0x10)`).
- ✅ Phase 1 focused static scan completed (`Slither` priority detectors + `Semgrep auto`).
  - Artifact: `slither-findings.md`
  - Result: no confirmed High/Medium issues from this focused pass
- ✅ PayoutRouter migrated to accumulator pull model:
  - `recordYield(asset, totalYield)` + `claimYield(vault, asset)` implemented
  - `distributeToAllUsers` push loop removed from code path
  - `updateUserShares(address user, uint256 newShares)` binds vault to `msg.sender`
  - Full suite green after migration (`forge test -v`: 224/224)
- ✅ Phase 2 unit-test gap fill completed:
  - Added `test/unit/TestContract07_NGORegistry.t.sol`
  - Added `test/unit/TestContract10_CampaignVaultFactory.t.sol`
  - Added `test/unit/TestContract11_AdapterKinds.t.sol`
  - Added `test/unit/TestContract12_ModuleLibraries.t.sol`
  - Verification: `forge test --match-path "test/unit/**" -v` passes (21/21)
- ⚠️ Additional planned test suites are still missing (`test/fuzz`, `test/invariant`, `test/fork`).

### Mandatory Deployment Gates (No Exceptions)

1. `forge test -v` passes with zero failures.
2. PayoutRouter accumulator (pull) model is fully implemented and old push loop removed.
3. Slither + Semgrep findings triaged, with no unaccepted unresolved High issues.
4. Fuzz + invariant suites exist and pass.
5. Base fork tests pass against live Aave assumptions.
6. Tenderly scenario validation complete (happy path + emergency + governance + fee + gas).

If any gate fails, deployment is blocked.

---

## Execution Order

### Phase 0A — Stabilize Baseline (NEW, Required Before Any New Work)

Fix current failing tests first (CampaignRegistry deposit refund path) and re-establish a green
baseline:

```bash
forge test -v
```

No architecture migration or new test suites until baseline is green.

**Status (2026-02-19): ✅ COMPLETE**

- Root cause: test actor `proposer = address(0x10)` collided with precompile behavior,
  causing `approveCampaign` refund transfer to revert with `DepositTransferFailed()` in tests.
- Fix applied: updated actor addresses in `test/TestContract03_CampaignRegistry.t.sol`
  to non-precompile addresses (`0x1001`+ range).
- Verification: `forge test --match-path test/TestContract03_CampaignRegistry.t.sol -v`
  and `forge test -v` both pass.

---

### Phase 0 — Pre-flight: Bug Fixes

Fix the three bugs above. Run existing tests to confirm nothing regresses:

```bash
forge test --match-path "test/**" -v
```

All existing tests must pass before proceeding.

---

### Phase 1 — Static Analysis with Slither

**Claude skill:** `semgrep` (for custom rule scans) — invoke with `/semgrep`
**Also run:** Slither manually (no dedicated skill, run via Bash)

Slither catches pattern-level issues the manual review may miss: unused state, unbounded loops,
dangerous `call` return value ignores, ERC compliance deviations.

**Setup:**

```bash
uv add slither-analyzer
```

**Run:**

```bash
slither . \
  --compile-force-framework foundry \
  --filter-paths "lib/,node_modules/" \
  --exclude-dependencies \
  --json slither-report.json 2>&1 | tee slither-output.txt
```

**Triage priorities — focus on these detectors, ignore the rest initially:**

- `unused-state` — confirms the dead `feeBps` variable
- `costly-loop` — flags `distributeToAllUsers` O(n) loop and `_removeShareholder` O(n) scan
- `unchecked-lowlevel` — flags any `.call{}()` without return value check
- `reentrancy-eth` / `reentrancy-no-eth` — verify reentrancy guards are sufficient
- `arbitrary-send-eth` — flags ETH sends in `approveCampaign` deposit refund
- `divide-before-multiply` — basis points calculations

**False positives to filter out:**

- `uninitialized-local` on Diamond Storage `assembly` blocks — expected, not a bug
- `constable-states` on role `bytes32` constants — intentional
- `tautology` warnings on SafeCast usage — OZ library noise

After triage, create `slither-findings.md` documenting confirmed findings vs dismissed noise.

**Status (2026-02-19): ✅ FOCUSED SCAN COMPLETE**

- Slither (priority detectors): 3 findings, all triaged as dismissed/intentional.
- Semgrep (`--config auto` on `src/`): 0 findings.
- Report written to `slither-findings.md`.

---

### Phase 1 Results — Slither Triage (Historical Snapshot; Revalidate Before Mainnet)

Ran via Slither MCP on 2026-02-19. Full counts: 79 contracts, 15 high / 24 medium raw findings.

#### CONFIRMED — Must Fix

None at the time of that run. Revalidation is still required after any material code changes,
especially PayoutRouter migration and CampaignRegistry fixes.

#### DISMISSED — False Positives

| Detector                 | Location                                         | Reason dismissed                                                                                                              |
| ------------------------ | ------------------------------------------------ | ----------------------------------------------------------------------------------------------------------------------------- |
| `arbitrary-send-erc20`   | `MockYieldAdapter`                               | Mock contract, not deployed                                                                                                   |
| `reentrancy-eth`         | `GiveVault4626.depositETH`                       | Protected by `nonReentrant`; WETH is trusted                                                                                  |
| `reentrancy-balance`     | `GiveVault4626._ensureSufficientCash`            | All callers are `nonReentrant`; adapters are permissioned                                                                     |
| `reentrancy-no-eth`      | `_deposit`, `_withdraw`, `emergencyWithdrawUser` | `nonReentrant` on all public entry points                                                                                     |
| `reentrancy-no-eth`      | `AaveAdapter.harvest`                            | `totalInvested` protected by `onlyVault`                                                                                      |
| `divide-before-multiply` | `GrowthAdapter.divest`                           | Intentional inverse calculation (shares ↔ assets)                                                                             |
| `incorrect-equality`     | `AaveAdapter` (`aTokenBalance == 0`)             | Standard zero-balance guard                                                                                                   |
| `incorrect-equality`     | `emergencyWithdrawUser` (`assets == 0`)          | Protective `ZeroAmount` revert                                                                                                |
| `incorrect-equality`     | `CampaignRegistry.finalizeStakeExit`             | `pendingWithdrawal == 0` is valid sentinel                                                                                    |
| `unused-state`           | (none found)                                     | `feeBps` fix confirmed working                                                                                                |
| `costly-loop`            | (none found by Slither)                          | O(n) DoS risk in `distributeToAllUsers` still documented for fork gas tests                                                   |
| `unprotected-upgrade`    | 8 UUPS contracts                                 | EIP-6780 (Cancun) made `selfdestruct` a no-op for existing contracts; attack vector obsolete on Prague+ chains (Base mainnet) |
| `arbitrary-send-eth`     | `CampaignRegistry.sol:431`                       | Code already checks return value and reverts with `DepositTransferFailed()` — Slither false positive                          |
| `uninitialized-local`    | `StrategyRegistry.sol:336`                       | `removed` intentionally relies on zero-default bool; not a logic error                                                        |
| `uninitialized-local`    | `EmergencyModule.sol:188`                        | `params` intentionally relies on zero-default struct; not a logic error                                                       |

---

### Phase 1.5 — Fix Confirmed Slither Findings (Historical; Re-run Required)

All raw confirmed findings were investigated and dismissed at that time. This does not replace a
fresh run before deployment.

- **HIGH-1 `unprotected-upgrade`** — DISMISSED. EIP-6780 (Cancun) rendered `selfdestruct`
  a no-op for existing contracts. The attack path (initialize impl → delegatecall selfdestruct)
  is fully obsolete on Prague+ chains including Base mainnet.
- **HIGH-2 `arbitrary-send-eth`** — DISMISSED. `CampaignRegistry.sol:431` already checks the
  return value and reverts with `DepositTransferFailed()`. Slither false positive.
- **MEDIUM-1 `uninitialized-local` (`removed`)** — DISMISSED. Intentional zero-default bool in
  `StrategyRegistry.unregisterStrategyVault`; not a logic error.
- **MEDIUM-2 `uninitialized-local` (`params`)** — DISMISSED. Intentional zero-default struct in
  `EmergencyModule._emergencyWithdraw`; not a logic error.

Compiler and EVM version updated as part of this phase closure:

- `solc`: `0.8.26` → `0.8.34` (latest stable, released 2026-02-18)
- `evm_version`: `cancun` → `prague` (stable default since 0.8.30; Pectra upgrade)

**Semgrep scan** (still pending):

```bash
# Run via /semgrep skill — it auto-detects Solidity and spawns parallel workers
```

The semgrep skill will run Solidity-specific rulesets and produce a SARIF report. Use the
`sarif-parsing` skill to aggregate and deduplicate results from both Slither and Semgrep.

---

### Phase 1.6 — PayoutRouter Architectural Audit Findings

**Status (2026-02-19): ✅ COMPLETE**

- ✅ `updateUserShares` hardened (vault inferred from `msg.sender`) and call sites updated.
- ✅ Push distribution removed in favor of accumulator pull model (`recordYield` + `claimYield`).
- ✅ No shareholder enumeration in active payout path.
- ✅ Verification: `forge test --match-path test/TestContract06_PayoutRouter.t.sol -v` and
  `forge test -v` pass (224/224).

Manual audit of `PayoutRouter.sol` identified five medium-severity findings. Four share a
single root cause (push distribution model); one is an independent access-control gap.

#### Findings

**MEDIUM-A: `_removeShareholder` O(n) DoS**
`updateUserShares` calls `_removeShareholder` which does a linear scan of `vaultShareholders`
to find and remove the user. At ≈10k–20k shareholders this scan exceeds safe gas limits,
blocking withdrawals if the vault reverts on `updateUserShares` failure.

**MEDIUM-B: Cross-vault share manipulation**
`updateUserShares(user, vault, newShares)` accepted an arbitrary `vault` parameter but only
checked `onlyAuthorized`. Any authorized caller could inflate shares for users in a vault it did
not own. When the victim vault later called `distributeToAllUsers`, the poisoned
`totalVaultShares` diluted legitimate holders' yield.

**Fix applied (2026-02-19):** API changed to
`updateUserShares(address user, uint256 newShares)` and vault is always inferred as `msg.sender`.

**MEDIUM-C: Cross-vault asset drain**
`distributeToAllUsers(asset, totalYield)` distributes from the router's shared ERC20 balance.
There is no per-vault balance ledger, so an authorized caller can claim tokens that were
deposited by a different vault.

**MEDIUM-D: Malicious beneficiary grief**
`distributeToAllUsers` transfers directly to `beneficiary` inside the shareholder loop. A user
whose beneficiary is a contract that reverts on `transfer` will cause the entire distribution
call to revert, blocking yield for all shareholders in that vault permanently.

**MEDIUM-E: Unbounded loop in `distributeToAllUsers`**
The distribution loop iterates `vaultShareholders[msg.sender]` and may execute ERC20 transfers
per iteration. Gas scales linearly; at sufficient scale the function becomes unexecutable.
Previously flagged as a fork-gas test risk — confirmed here as a structural design issue.

#### Root Cause

Findings A, C, D, E all stem from the **push distribution model**: one vault call enumerates
all shareholders, computes allocations, and transfers tokens in a single transaction.
Patching individual symptoms (pagination, try/catch on transfers) leaves the model fragile.
The correct fix is a full architectural replacement.

#### Fix: Replace Push Model with Accumulator (Pull) Pattern

This is the standard approach used by Synthetix `StakingRewards`, Aave aTokens, and Compound
cTokens. Reference: "Scalable Reward Distribution on the Ethereum Blockchain" (Batog, Bünz,
Göbel, 2018).

**Core state replacing the shareholder array:**

```solidity
// Per-vault running yield accumulator, scaled by PRECISION (1e18)
mapping(address vault => mapping(address asset => uint256)) accumulatedYieldPerShare;

// Per-user snapshot of the accumulator at last claim or share-change
mapping(address vault => mapping(address asset => mapping(address user => uint256))) userYieldDebt;

// Per-user unclaimed yield (crystallised when shares change)
mapping(address vault => mapping(address asset => mapping(address user => uint256))) pendingYield;
```

The `vaultShareholders` array is **deleted entirely** — it is only needed for push iteration.

**New interface:**

```solidity
// Called by vault after transferring yield tokens to the router
// Replaces distributeToAllUsers — O(1), no loop, no transfers
function recordYield(address asset, uint256 totalYield) external onlyAuthorized;

// Called by user (or keeper) to collect accumulated yield for one vault+asset
function claimYield(address vault, address asset) external;

// Called by vault on deposit/withdrawal — vault is always msg.sender (fixes MEDIUM-B)
function updateUserShares(address user, uint256 newShares) external onlyAuthorized;
```

**Invariants the new design must satisfy:**

- `recordYield` updates `accumulatedYieldPerShare[msg.sender][asset]` only — never touches
  other vaults' accumulators (fixes MEDIUM-C)
- `updateUserShares` snapshots `pendingYield` at the old share count before applying the new
  count — prevents yield gain/loss on share changes
- `claimYield` is a separate per-user transaction — a reverted beneficiary transfer cannot
  affect other users (fixes MEDIUM-D)
- No array enumeration anywhere — fixes MEDIUM-A and MEDIUM-E
- `updateUserShares` accepts no `vault` parameter; vault is always `msg.sender` (fixes MEDIUM-B)

**What stays the same:**

- `setVaultPreference` (beneficiary + allocation percentage) — logic unchanged
- `executeFeeChange` / fee timelock — logic unchanged
- `onlyAuthorized` access control pattern — unchanged
- Per-user campaign/beneficiary/protocol split in `_calculateAllocations` — moves into
  `claimYield` rather than the old loop

**Migration note:** `vaultShareholders`, `hasVaultShare`, and the `_removeShareholder` helper
are dead code once the accumulator is in place — delete them all.

**Implementation order:**

1. Add accumulator state variables
2. Rewrite `updateUserShares` (remove `vault` param, add snapshot logic, remove array writes)
3. Replace `distributeToAllUsers` with `recordYield` (O(1) accumulator update + transfer in)
4. Implement `claimYield` (compute pending + debt, apply preference split, transfer out)
5. Delete `vaultShareholders`, `hasVaultShare`, `_removeShareholder`
6. Run `forge test -v` — update all tests referencing the old interface

---

### Phase 1.7 — PayoutRouter Vault Re-registration Finding

**Status (2026-02-19): ✅ COMPLETE**

- ✅ `claimYield` now auto-clears stale preferences on campaign mismatch and emits
  `StalePrefCleared(user, vault)`.
- ✅ `registerCampaignVault` now emits `VaultReassigned(vault, oldCampaignId, newCampaignId)`
  when a vault is re-mapped.

**INFO-1: Vault re-registration causes stale preferences, blocking individual yield claims**

`registerCampaignVault(vault, campaignId)` has no guard against re-registering a vault that
already has active users with stored preferences. `_calculateAllocations` checks:

```solidity
if (pref.campaignId != bytes32(0) && pref.campaignId != campaignId) {
    revert CampaignMismatch(campaignId, pref.campaignId);
}
```

After re-registration, any user whose stored `pref.campaignId` matches the old campaign hits
this revert.

**Severity after Phase 1.6:** The global DoS (one bad preference blocks all distributions) is
eliminated by the pull model — each `claimYield` call is independent. What remains: a user
with a stale preference cannot claim their accumulated yield until they call
`setVaultPreference` again. If they are unaware of the re-registration, yield sits unclaimed
indefinitely.

VAULT_MANAGER_ROLE is trusted (intentional griefing ruled out per severity note), but
accidental or legitimate campaign restructuring still triggers this.

#### Fixes

**Fix 1 — `claimYield`: auto-clear stale preferences instead of reverting**
When `pref.campaignId != 0 && pref.campaignId != currentCampaignId`, treat as no preference
(100% to current campaign), delete the stale entry, and emit `StalePrefCleared(user, vault)`.
Reverting here traps users silently; auto-clearing with an event is better UX with no loss of
safety (the user's funds are not affected, only their allocation preference resets to default).

**Fix 2 — `registerCampaignVault`: emit `VaultReassigned` event on campaign change**
When re-registering a vault to a different campaign, emit:

```solidity
event VaultReassigned(address indexed vault, bytes32 indexed oldCampaignId, bytes32 indexed newCampaignId);
```

This gives front-ends and off-chain monitors a signal to prompt affected users to update
their preferences.

**Phase 2 edge cases to add (PayoutRouter):**

```
- claimYield after vault re-registration with stale pref → auto-clears, distributes to new campaign
- claimYield with no preference set → 100% to campaign (default path)
- registerCampaignVault re-registration → emits VaultReassigned event
- registerCampaignVault re-registration → subsequent claimYield succeeds for stale-pref user
```

---

### Phase 2 — Foundry Unit Tests (gap fill)

**Status (2026-02-19): ✅ CORE UNIT GAP COMPLETE**

- Added all four missing `test/unit` files listed below.
- Verified new unit scope with `forge test --match-path "test/unit/**" -v` (21 passed, 0 failed).
- Remaining work for this phase is optional depth expansion from the edge-case backlog.

**Claude skill:** none required — standard Foundry
**Run:** `forge test --match-path "test/unit/**" -v`

The existing unit tests (TestContract01–09, TestAction01–02) cover happy paths. These files
are **missing** and must be written:

| File                                                  | Contracts Covered                                                                                          |
| ----------------------------------------------------- | ---------------------------------------------------------------------------------------------------------- |
| `test/unit/TestContract07_NGORegistry.t.sol`          | NGORegistry: approve/revoke, 24h timelock for `currentNGO`, KYC hash storage, cumulative donation tracking |
| `test/unit/TestContract10_CampaignVaultFactory.t.sol` | CampaignVaultFactory: CREATE2 address determinism, duplicate vault prevention, registry wiring             |
| `test/unit/TestContract11_AdapterKinds.t.sol`         | CompoundingAdapter, GrowthAdapter, ClaimableYieldAdapter, PTAdapter: invest/divest/harvest for each kind   |
| `test/unit/TestContract12_ModuleLibraries.t.sol`      | VaultModule, RiskModule, AdapterModule, EmergencyModule: all config paths and access control               |

**Priority edge cases to add to existing test files:**

```
GiveVault4626:
  - deposit when investPaused=true (after bug fix: should succeed)
  - forceClearAdapter with funds still in adapter (after bug fix: should revert)
  - setDonationRouter to address(0) → confirm revert
  - harvest with no shareholders in PayoutRouter → confirm behaviour

PayoutRouter (accumulator model — see Phase 1.6):
  - recordYield then claimYield → user receives correct split
  - recordYield when feeBps=0 → all net yield goes to campaign on claim
  - recordYield when feeBps=MAX_FEE_BPS → fee cap enforced on claim
  - proposeFeeChange then executeFeeChange → confirm s.feeBps used in claimYield split
  - cancel pending fee change → confirm no execution possible
  - updateUserShares from non-vault address → revert (vault == msg.sender check)
  - claimYield when beneficiary reverts → only that user's claim fails, others unaffected
  - recordYield from vault A, then vault B calls recordYield same asset → balances isolated
  - share change mid-accumulator: deposit, recordYield, deposit more, claimYield → correct pro-rata yield

CampaignRegistry:
  - voteOnCheckpoint before MIN_STAKE_DURATION elapses → NoVotingPower
  - finalizeCheckpoint with totalEligibleVotes==0 → auto-succeed path
  - updateCheckpointStatus skipping Voting → direct to Failed (admin bypass)
  - approveCampaign when proposer is a contract that reverts on receive → DepositTransferFailed

AaveAdapter:
  - harvest twice in sequence → verify totalInvested does not drift
  - divest more than invested → full exit, returns actual available
  - emergencyWithdraw when paused → confirm allowed (intentional)
```

---

### Phase 3 — Foundry Fuzz Tests

**Claude skill:** none required — standard Foundry fuzz
**Directory:** `test/fuzz/`
**Config update in `foundry.toml`:**

```toml
fuzz = { runs = 10000, max_test_rejects = 65536, seed = "0x1337" }
```

**Files to create:**

**`test/fuzz/FuzzVault.t.sol`**

```
fuzz_deposit_withdraw_roundtrip(uint256 assets, address receiver)
  assert: withdrawn >= deposited (no-loss at principal level)

fuzz_multiple_depositors(uint8 numUsers, uint256[8] amounts)
  assert: sum(balanceOf(user_i)) == totalSupply()
  assert: vault.getCashBalance() + adapter.totalAssets() == vault.totalAssets()

fuzz_share_price_nondecreasing(uint256 yieldAmount)
  deposit → accrue yield → harvest
  assert: previewRedeem(1e6) after >= previewRedeem(1e6) before

fuzz_cash_buffer_enforcement(uint256 assets, uint16 bufferBps)
  after deposit: assert vault cash balance <= totalAssets * cashBufferBps / 10000 + 1
```

**`test/fuzz/FuzzAaveAdapter.t.sol`**

```
fuzz_invest_divest_no_loss(uint256 assets)
  invest(assets) → divest(assets)
  assert: totalInvested == 0 after full exit

fuzz_harvest_accounting_no_drift(uint256 principal, uint256 yieldBps)
  invest → yield → harvest
  assert: profit == aToken.balanceOf(adapter) - totalInvested (before harvest)
  assert: totalInvested post-harvest == pre-harvest aToken balance - profit
```

**`test/fuzz/FuzzPayoutRouter.t.sol`**

```
fuzz_distribution_no_leakage(uint256 totalYield, uint8 numHolders, uint256[16] shares)
  assert: sum(payouts) <= totalYield
  assert: sum(campaignAmount + beneficiaryAmount + protocolAmount) == userYield per user

fuzz_fee_calculation_bounded(uint256 userYield, uint16 feeBps)
  assert: protocolAmount <= userYield * MAX_FEE_BPS / 10000
  assert: campaignAmount + beneficiaryAmount == userYield - protocolAmount
```

**`test/fuzz/FuzzCampaignRegistry.t.sol`**

```
fuzz_checkpoint_voting_eligibility(uint256 stakeAmount, uint64 stakeDelay, bool support)
  if stakeDelay < MIN_STAKE_DURATION: assert vote reverts NoVotingPower
  if stakeDelay >= MIN_STAKE_DURATION: assert vote recorded correctly

fuzz_quorum_finalization(uint208 votesFor, uint208 votesAgainst, uint208 eligible, uint16 quorumBps)
  result = (votesFor + votesAgainst) >= (quorumBps * eligible / 10000)
         && votesFor > votesAgainst ? Succeeded : Failed
  assert: finalizeCheckpoint matches this formula exactly
```

**Run:**

```bash
forge test --match-path "test/fuzz/**" -v --fuzz-seed 0x1337
```

---

### Phase 4 — Foundry Invariant Tests

**Claude skill:** `property-based-testing` — invoke with `/property-based-testing` for guidance
on handler design and invariant selection before writing code.
**Directory:** `test/invariant/`
**Config update in `foundry.toml`:**

```toml
[invariant]
runs = 256
depth = 500
fail_on_revert = false
```

**Files to create:**

**`test/invariant/handlers/VaultHandler.sol`**
Actions: `deposit`, `withdraw`, `redeem`, `harvest`, `accrueYield`, `investExcess`, `divest`

**`test/invariant/InvariantVault.t.sol`**

```
invariant_total_assets_covers_deposits
  totalAssets() >= sum(deposits) - sum(withdrawals)

invariant_erc4626_accounting_consistent
  convertToAssets(totalSupply()) == totalAssets()  (±1 rounding)

invariant_share_sum_equals_total_supply
  sum(balanceOf(tracked_user)) == totalSupply()

invariant_cash_plus_adapter_equals_total
  vault.getCashBalance() + adapter.totalAssets() == vault.totalAssets()

invariant_share_price_nondecreasing
  previewRedeem(1e18) >= INITIAL_EXCHANGE_RATE
```

**`test/invariant/handlers/PayoutRouterHandler.sol`**
Actions: `deposit`, `harvest`, `setPreference`, `updateShares`, `emergencyWithdraw`

**`test/invariant/InvariantPayoutRouter.t.sol`**

```
invariant_payout_never_exceeds_yield
  campaignTotalPayouts[id] <= totalYieldHarvestedByVault[id]

invariant_shareholder_list_consistent
  vaultShareholders[v].length == count(u: userVaultShares[u][v] > 0)

invariant_fee_bounded
  campaignProtocolFees[id] <= campaignTotalPayouts[id] * MAX_FEE_BPS / 10000
```

**`test/invariant/handlers/CampaignRegistryHandler.sol`**
Actions: `submitCampaign`, `approveCampaign`, `rejectCampaign`, `recordStake`, `requestExit`,
`scheduleCheckpoint`, `vote`, `finalizeCheckpoint`

**`test/invariant/InvariantCampaignRegistry.t.sol`**

```
invariant_deposit_always_zeroed_after_decision
  if status in {Approved, Rejected}: cfg.initialDeposit == 0

invariant_payouts_halted_only_on_failed_checkpoint
  cfg.payoutsHalted == true → exists checkpoint[i].status == Failed

invariant_stake_accounting_consistent
  totalActive + totalPendingExit == sum(stake.shares + stake.pendingWithdrawal) for all supporters

invariant_no_vote_without_stake_duration
  if hasVoted[user]: stake.stakeTimestamp + MIN_STAKE_DURATION <= vote_timestamp
```

**Run:**

```bash
forge test --match-path "test/invariant/**" -v
```

---

### Phase 5 — Hardhat Fork Tests (JSON-RPC against real Aave V3)

**Claude skill:** none — standard Hardhat/ethers.js
**Directory:** `test/fork/`
**Purpose:** Validate AaveAdapter against real Aave V3 state, gas profiling at real scale,
and JSON-RPC connection validation.

**Install dependencies:**

```bash
pnpm add -D hardhat @nomicfoundation/hardhat-toolbox @nomicfoundation/hardhat-ethers ethers
pnpm add -D @aave/core-v3  # for typed interfaces
```

**`hardhat.config.ts`**

```typescript
import { HardhatUserConfig } from "hardhat/config";
import "@nomicfoundation/hardhat-toolbox";

const config: HardhatUserConfig = {
  solidity: {
    version: "0.8.26",
    settings: { optimizer: { enabled: true, runs: 200 }, viaIR: true },
  },
  networks: {
    hardhat: {
      forking: {
        url: process.env.BASE_RPC_URL!, // Base mainnet — Aave V3 deployed
        blockNumber: undefined, // pin after first run for reproducibility
        enabled: true,
      },
      chainId: 8453,
    },
  },
};
export default config;
```

**`.env` (gitignored):**

```
BASE_RPC_URL=https://base-mainnet.g.alchemy.com/v2/<YOUR_KEY>
```

**Test files:**

**`test/fork/AaveAdapter.fork.ts`** — real Aave V3 on Base

```typescript
// Addresses: Base mainnet Aave V3
const AAVE_POOL = "0xA238Dd80C259a72e81d7e4664a9801593F98d1c5";
const USDC = "0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913";
const AUSDC = "<aUsdc address from getReserveData>";
const WHALE = "<USDC whale on Base>";

it("invest: transfers USDC to Aave and receives aUSDC");
it("totalAssets: equals aToken.balanceOf(adapter)");
it("harvest: accrues real yield after time.increase(30 days)");
it("divest: returns correct USDC within slippage bounds");
it("divest full: totalInvested resets to 0");
it("emergencyWithdraw: recovers all aUSDC to vault");
it("isHealthy: returns true on live reserve");
```

**`test/fork/GiveVault.fork.ts`** — full vault cycle on real network

```typescript
it(
  "full cycle: deposit → invest → 30-day yield → harvest → distribute → withdraw",
);
// assert: donor principal intact after withdrawal (±slippage)
// assert: NGO received nonzero USDC

it("share price: nondecreasing after 90-day yield accrual");

it("emergency: pause + emergencyWithdraw from real Aave within same block");

it("totalAssets: matches actual on-chain balances before and after harvest");
```

**`test/fork/PayoutRouter.gas.fork.ts`** — gas profiling (critical for O(n) loop)

```typescript
const SHAREHOLDER_COUNTS = [10, 50, 100, 200];

for (const n of SHAREHOLDER_COUNTS) {
  it(`distributeToAllUsers with ${n} shareholders: gas < limit`, async () => {
    // fund n wallets, deposit into vault, harvest, measure gas
    // WARN if gas > 2_000_000 (approaching safe limit for Base)
    // FAIL  if gas > 8_000_000 (Base block gas limit)
  });
}
// Expected: 200 shareholders will approach or exceed limits — documents the DoS risk
```

**`test/fork/rpc.connection.ts`** — RPC and fork sanity checks (run first)

```typescript
it("RPC: can connect to Base mainnet and read latest block");
it("RPC: Aave V3 pool is deployed at expected address");
it("RPC: USDC reserve is active and not frozen");
it("RPC: forked block number is within 1000 blocks of current tip");
it("RPC: state override (impersonation) works for whale account");
```

**Run:**

```bash
BASE_RPC_URL=$BASE_RPC_URL npx hardhat test test/fork/rpc.connection.ts
BASE_RPC_URL=$BASE_RPC_URL npx hardhat test test/fork/ --network hardhat
```

---

### Phase 6 — Tenderly Simulation (real adapters, full protocol stack)

**Claude skill:** none — use Tenderly dashboard + `tenderly` CLI
**Purpose:** End-to-end validation of the full deployed protocol against live Aave V3 state,
without spending real funds. Confirms deployment scripts and operational flows work.

**Setup:**

```bash
npm install -g @tenderly/cli
tenderly login
tenderly init   # link to your Tenderly project
```

**`tenderly.yaml`** (project root):

```yaml
account_id: <your-username>
project_slug: give-protocol
```

**Create a Virtual Testnet** (via Tenderly dashboard or CLI):

- Base mainnet fork, latest block
- Give yourself USDC via state override (whale impersonation or balance slot override)

**Deploy full protocol into virtual testnet:**

```bash
# Set RPC to Tenderly virtual testnet RPC URL
DEPLOYMENT_RPC=<tenderly-vnet-rpc> forge script script/Deploy01_Infrastructure.s.sol \
  --rpc-url $DEPLOYMENT_RPC --broadcast

DEPLOYMENT_RPC=<tenderly-vnet-rpc> forge script script/Deploy02_VaultsAndAdapters.s.sol \
  --rpc-url $DEPLOYMENT_RPC --broadcast

DEPLOYMENT_RPC=<tenderly-vnet-rpc> forge script script/Deploy03_Initialize.s.sol \
  --rpc-url $DEPLOYMENT_RPC --broadcast
```

**Simulation Scenarios (run via Tenderly dashboard or Foundry scripts):**

**Scenario A — Happy Path Campaign**

```
1.  submitCampaign (0.005 ETH deposit attached)
2.  approveCampaign → verify deposit refunded to proposer
3.  CampaignVaultFactory.createVault
4.  registerCampaignVault in PayoutRouter
5.  3 donors deposit real USDC (state-overridden balances)
6.  setActiveAdapter → real AaveAdapter pointing at Base Aave V3
7.  Deposits auto-invest via _investExcessCash
8.  Time travel +30 days (Tenderly time override)
9.  harvest() → real yield flows through PayoutRouter to NGO
10. verify NGO wallet received USDC
11. all donors redeem → verify principal returned within maxLoss tolerance
```

**Scenario B — Emergency Recovery**

```
1. Fund vault with active Aave position (from Scenario A)
2. emergencyPause → verify emergencyWithdraw pulls all aUSDC from real Aave
3. Confirm vault holds USDC (not aUSDC)
4. Wait EMERGENCY_GRACE_PERIOD (24h time travel)
5. All donors call emergencyWithdrawUser
6. Assert: sum(withdrawn) >= sum(deposited) - dust
```

**Scenario C — Checkpoint Governance + Payout Halt**

```
1. Active vault with accrued yield (skip to after yield injection)
2. scheduleCheckpoint with quorumBps=9000 (will fail)
3. updateCheckpointStatus → Voting
4. donor1 votes false (against), quorum not met
5. finalizeCheckpoint → Failed → payoutsHalted=true
6. harvest() → assert reverts OperationNotAllowed
7. scheduleCheckpoint with quorumBps=1000 (will pass)
8. donor1+donor2 vote true → Succeeded → payoutsHalted=false
9. harvest() → succeeds, yield distributed
```

**Scenario D — Fee Governance Validation (confirms bug fix)**

```
1. proposeFeeChange from 250bps to 400bps
2. executeFeeChange immediately → assert revert (timelock)
3. Time travel +7 days
4. executeFeeChange → assert s.feeBps == 400
5. harvest + distributeToAllUsers
6. assert: protocolAmount uses 400bps (not hardcoded 250bps)
   → This test FAILS before the feeBps bug is fixed. Use it to confirm the fix.
```

**Scenario E — Gas DoS Validation**

```
1. Register 200 shareholders in a single vault
2. harvest() → measure gas via Tenderly gas profiler
3. If gas > 8_000_000: document as confirmed DoS vector, file as critical
```

**Tenderly Gas Profiler:** After each simulation, open the transaction in Tenderly dashboard
→ "Gas Profiler" tab → export call breakdown. Save as `tenderly-gas-<scenario>.json`.

---

## Running All Phases in Order (Enforced)

```bash
# Phase 0A: baseline must be green first
forge test -v

# STOP if failing. Do not continue until green.

# Phase 1: static analysis
slither . --compile-force-framework foundry --filter-paths "lib/,node_modules/" \
  --exclude-dependencies --json slither-report.json
# then: /semgrep   (invoke skill)
# then: /sarif-parsing   (invoke skill to aggregate slither + semgrep output)

# Phase 2: unit tests (including missing files to be created)
forge test --match-path "test/unit/**" -v

# Phase 3: fuzz (requires foundry.toml fuzz runs update)
forge test --match-path "test/fuzz/**" -v --fuzz-seed 0x1337

# Phase 4: invariant (requires [invariant] config in foundry.toml)
forge test --match-path "test/invariant/**" -v

# Phase 5: fork (Hardhat)
BASE_RPC_URL=$BASE_RPC_URL npx hardhat test test/fork/rpc.connection.ts
BASE_RPC_URL=$BASE_RPC_URL npx hardhat test test/fork/

# Phase 6: Tenderly (manual — run scenarios in dashboard or via deploy scripts)

# Final gate: rerun full Foundry + static analysis after all fixes
forge test -v
slither . --compile-force-framework foundry --filter-paths "lib/,node_modules/" \
  --exclude-dependencies --json slither-report-final.json
```

---

## Claude Skills Reference

| Phase     | Skill                        | When to invoke                                                                             |
| --------- | ---------------------------- | ------------------------------------------------------------------------------------------ |
| Phase 1   | `semgrep`                    | After Slither — run parallel Solidity static analysis                                      |
| Phase 1   | `sarif-parsing`              | Aggregate + deduplicate Slither JSON + Semgrep SARIF output                                |
| Phase 1   | `guidelines-advisor`         | Review architecture decisions against Trail of Bits best practices                         |
| Phase 2–4 | `audit-context-building`     | Before writing a test for a complex flow — builds deep line-by-line context                |
| Phase 4   | `property-based-testing`     | Handler design guidance and invariant selection before writing invariant tests             |
| Phase 2–6 | `entry-point-analyzer`       | Enumerate all state-changing entry points to ensure test coverage is complete              |
| Phase 2–6 | `token-integration-analyzer` | Verify ERC20 (USDC, DAI) integration correctness — particularly fee-on-transfer edge cases |
| Any       | `variant-analysis`           | After finding a bug — hunt for the same pattern elsewhere in the codebase                  |
| Any       | `code-maturity-assessor`     | Score the codebase across 9 categories before a formal audit engagement                    |
| Any       | `differential-review`        | Review any PR against this plan — flags security regressions in diffs                      |

---

## Project-Specific Conventions

- All test files use `forge-std` — no Hardhat in Foundry tests
- Fork tests live in `test/fork/` (Hardhat only) — never mix with Foundry test directory
- Invariant handlers go in `test/invariant/handlers/` — separate from test contracts
- Gas limits on Base: block limit ~120M gas, safe per-tx limit ~8M
- Slippage budget: AaveAdapter `maxSlippageBps` defaults to 100 (1%) — test within this bound
- Never use `vm.prank` on the vault address to call adapter directly in tests — use the
  production `harvest()` / `_investExcessCash()` path where possible
