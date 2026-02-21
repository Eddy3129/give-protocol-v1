# Slither + Semgrep Findings (Phase 1)

Date: 2026-02-19

## Scope

- Path: `.`
- Excluded paths: `lib/`, `node_modules/`, `test/`
- Slither detectors:
  - `unused-state`
  - `costly-loop`
  - `unchecked-lowlevel`
  - `reentrancy-eth`
  - `reentrancy-no-eth`
  - `arbitrary-send-eth`
  - `divide-before-multiply`

## Commands Run

```bash
uv tool run --from slither-analyzer slither . \
  --compile-force-framework foundry \
  --filter-paths "lib/,node_modules/" \
  --exclude-dependencies \
  --detect unused-state,costly-loop,unchecked-lowlevel,reentrancy-eth,reentrancy-no-eth,arbitrary-send-eth,divide-before-multiply \
  --json slither-report.json

uv tool run --from semgrep semgrep --config auto src --exclude test --exclude lib --json --output semgrep-report.json
```

## Slither Results

Total findings: **3**

### 1) `reentrancy-no-eth`

- Location: `src/adapters/AaveAdapter.sol` (`harvest`)
- Summary: external call (`aavePool.withdraw`) before state update (`totalInvested`).
- Triage: **DISMISSED (false positive)**
- Reason: `harvest` is guarded by `onlyVault` and `nonReentrant`; adapter entrypoints are permissioned and not user-accessible.

### 2) `divide-before-multiply`

- Location: `src/adapters/kinds/GrowthAdapter.sol` (`divest`)
- Summary: division followed by multiplication in normalized/returned conversion.
- Triage: **DISMISSED (intentional arithmetic path)**
- Reason: this is expected normalization math for growth index conversion and is capped by `totalDeposits`.

### 3) `arbitrary-send-eth`

- Location: `src/registry/CampaignRegistry.sol` (`approveCampaign`)
- Summary: ETH send to proposer via low-level call.
- Triage: **DISMISSED (expected behavior)**
- Reason: proposer is the campaign submitter by design; return value is explicitly checked and function reverts on failure (`DepositTransferFailed`).

## Semgrep Results

- Findings: **0**
- Rules run: 69
- Targets scanned: 36 files under `src/`

## Outcome

- Confirmed High/Medium issues from this focused scan: **none**
- Code changes required from Phase 1 scan: **none**
- Next blocking item remains Phase 1.6 architectural migration of `PayoutRouter` to accumulator pull model.
