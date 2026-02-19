# GIVE Protocol — Concise Status Summary

Last updated: 2026-02-19

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
- `test/fork/PendleAdapter.fork.t.sol`
- `script/Deploy02_VaultsAndAdapters.s.sol`
- `script/Deploy03_Initialize.s.sol`
- `test/base/Base02_DeployVaultsAndAdapters.t.sol`
- `foundry.toml`
- `.gitmodules`

Verify:

- `forge test --match-path test/unit/TestContract13_PendleAdapter.t.sol -v`
- `forge test --match-path test/fork/PendleAdapter.fork.t.sol -v`
- `forge test --match-path test/integration/TestAction02_MultiStrategyOperations.t.sol -v`

### Update H — Fork Gap Coverage Additions (Complete for GAP-1..5)

Added/validated fork suites:

Files:

- `test/fork/DepositETH.fork.t.sol` (GAP-1)
- `test/fork/CompoundingAdapterWstETH.fork.t.sol` (GAP-2)
- `test/fork/MultiVaultCampaign.fork.t.sol` (GAP-4)
- `test/fork/CheckpointVoting.fork.t.sol` (GAP-5)
- `test/fork/ForkAddresses.sol`
- `test/fork/ForkBase.t.sol`

Additional hardening from fork feedback:

- `src/adapters/AaveAdapter.sol` (`divest` full-withdraw/slippage accounting)
- fork test tolerance updates in `test/fork/`

Verify:

- `forge test --match-path test/fork/DepositETH.fork.t.sol -v`
- `forge test --match-path test/fork/CompoundingAdapterWstETH.fork.t.sol -v`
- `forge test --match-path test/fork/MultiVaultCampaign.fork.t.sol -v`
- `forge test --match-path test/fork/CheckpointVoting.fork.t.sol -v`
- `forge test --match-path test/fork/AaveAdapter.fork.t.sol -v`
- `forge test --match-path test/fork/ForkSanity.fork.t.sol -v`
- `forge test --match-path test/fork/GiveVault.fork.t.sol -v`
- `forge test --match-path test/fork/PayoutRouterGas.fork.t.sol -v`

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
forge test --match-path "test/fork/PendleAdapter.fork.t.sol" -v
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

## Pending / Future Improvements (Only Uncovered Items)

### GAP-6 (Lower Priority)

No dedicated fork suites yet for:

- `GrowthAdapter`
- `ClaimableYieldAdapter`
- `ManualManageAdapter`

Reason: no strong live Base deployment target for realistic fork behavior (mostly mock-worthy).

### Tenderly Phase (Pending)

Scenario validation still pending:

- Happy path
- Emergency recovery
- Checkpoint halt/resume
- Fee timelock validation
- Gas profile exports

### Optional Depth Work (Not Blockers for Current Scope)

- Add fork block pinning runbook for strict reproducibility
- Add operator-facing PT listing runbook in `README.md`
- Extend reporting around value-accrual assets (wstETH/cbETH) in UI/docs

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
forge test --match-path "test/fork/ForkSanity*" --fork-url $BASE_RPC_URL -v
forge test --match-path "test/fork/**" --fork-url $BASE_RPC_URL -v
```

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
