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

## Frontend Integration Flow (Complete Through Phase 5)

### Phase 5 — Done

| Check | Tool | Status |
|---|---|---|
| Local lifecycle (approve → deposit → redeem) | viem + Anvil | ✓ |
| PayoutRouter share tracking after deposit | viem + Anvil | ✓ |
| ERC-4626 conversion parity | viem + Anvil | ✓ |
| Revert selector mapping | viem + Anvil | ✓ |
| Event log queries | viem + Anvil | ✓ |
| Live Base RPC protocol connectivity | viem --mode=rpc | ✓ |
| USDC, Aave, wstETH, Pendle on Base | viem --mode=rpc | ✓ |
| Base fork full lifecycle against real USDC/Aave | viem + fork Anvil | ✓ |
| Multi-chain config layer (Arbitrum, Optimism) | config/chains/ | ✓ |

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

| Revert | User-facing message |
|---|---|
| `ERC4626ExceededMaxRedeem` | "Insufficient shares to redeem" |
| `InsufficientCash` | "Vault is rebalancing, try again shortly" |
| `ExcessiveLoss` | "Withdrawal paused due to slippage" |
| `EnforcedPause` | "Vault is paused" |
| `GracePeriodExpired` | "Emergency period ended, contact support" |
| `ZeroAmount` | "Amount must be greater than zero" |

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
