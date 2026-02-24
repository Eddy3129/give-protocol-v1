# Coverage Report (Auditor Snapshot)

Generated: 2026-02-24
Command: `make coverage-summary`
Scope: unit + integration coverage run (`--no-match-path "test/fork/**:test/fuzz/**:test/invariant/**"`)
Tests run: **438 passed, 0 failed, 0 skipped**

> This report focuses on audit interpretation of the latest summary output.
> Global totals include `script/`, `test/`, and non-production files.

---

## 1) Global Coverage (all included files)

| Metric     | Coverage           |
| ---------- | ------------------ |
| Lines      | 63.35% (2538/4006) |
| Statements | 63.36% (2674/4220) |
| Branches   | 43.81% (283/646)   |
| Functions  | 66.25% (428/646)   |

Interpretation:

- Global percentages are diluted by script/test/helper files and intentionally excluded suites.
- Audit decisions should prioritize `src/` branch metrics on value-flow contracts.

---

## 2) Audit-Critical Production Contracts (`src/`)

| Contract                            | Lines  | Statements | Branches | Functions |
| ----------------------------------- | ------ | ---------- | -------- | --------- |
| `src/vault/GiveVault4626.sol`       | 87.88% | 88.76%     | 77.97%   | 81.13%    |
| `src/payout/PayoutRouter.sol`       | 86.33% | 83.95%     | 65.12%   | 90.70%    |
| `src/registry/CampaignRegistry.sol` | 86.97% | 83.75%     | 51.47%   | 86.21%    |
| `src/manager/StrategyManager.sol`   | 77.97% | 76.56%     | 72.73%   | 77.27%    |
| `src/adapters/AaveAdapter.sol`      | 57.80% | 60.94%     | 18.52%   | 44.44%    |

High-confidence supporting contracts:

- `ACLManager`: 99.25% lines, 88.46% branches
- `CampaignVaultFactory`: 96.61% lines, 92.31% branches
- `StorageLib`: 87.37% lines, 100% branches
- `StrategyRegistry`: 94.38% lines, 84.21% branches

---

## 3) Full `src/` Contract Table (latest run)

| Contract                                       | Lines  | Stmts  | Branches | Funcs  |
| ---------------------------------------------- | ------ | ------ | -------- | ------ |
| `src/governance/ACLManager.sol`                | 99.25% | 97.87% | 88.46%   | 100%   |
| `src/core/GiveProtocolCore.sol`                | 100%   | 100%   | 100%     | 100%   |
| `src/adapters/base/AdapterBase.sol`            | 100%   | 100%   | 100%     | 100%   |
| `src/modules/AdapterModule.sol`                | 100%   | 100%   | 100%     | 100%   |
| `src/modules/DonationModule.sol`               | 100%   | 100%   | 100%     | 100%   |
| `src/modules/SyntheticModule.sol`              | 100%   | 100%   | 100%     | 100%   |
| `src/modules/VaultModule.sol`                  | 100%   | 100%   | 100%     | 100%   |
| `src/utils/ACLShim.sol`                        | 100%   | 100%   | 100%     | 100%   |
| `src/adapters/kinds/ClaimableYieldAdapter.sol` | 100%   | 100%   | 100%     | 100%   |
| `src/registry/StrategyRegistry.sol`            | 94.38% | 94.59% | 84.21%   | 100%   |
| `src/adapters/kinds/PendleAdapter.sol`         | 94.44% | 92.96% | 63.64%   | 83.33% |
| `src/adapters/kinds/CompoundingAdapter.sol`    | 93.94% | 87.88% | 57.14%   | 100%   |
| `src/adapters/kinds/ManualManageAdapter.sol`   | 93.51% | 94.74% | 89.47%   | 90.91% |
| `src/vault/CampaignVault4626.sol`              | 96.77% | 91.18% | 25.00%   | 100%   |
| `src/modules/EmergencyModule.sol`              | 97.06% | 88.24% | 63.64%   | 100%   |
| `src/donation/NGORegistry.sol`                 | 91.22% | 82.14% | 42.31%   | 96.15% |
| `src/factory/CampaignVaultFactory.sol`         | 96.61% | 96.20% | 92.31%   | 100%   |
| `src/adapters/kinds/GrowthAdapter.sol`         | 92.00% | 95.45% | 60.00%   | 83.33% |
| `src/adapters/kinds/PTAdapter.sol`             | 84.78% | 82.35% | 33.33%   | 75.00% |
| `src/payout/PayoutRouter.sol`                  | 86.33% | 83.95% | 65.12%   | 90.70% |
| `src/manager/StrategyManager.sol`              | 77.97% | 76.56% | 72.73%   | 77.27% |
| `src/modules/RiskModule.sol`                   | 83.02% | 84.85% | 75.00%   | 80.00% |
| `src/registry/CampaignRegistry.sol`            | 86.97% | 83.75% | 51.47%   | 86.21% |
| `src/vault/VaultTokenBase.sol`                 | 82.35% | 73.68% | 33.33%   | 100%   |
| `src/storage/GiveStorage.sol`                  | 66.67% | 50.00% | 100%     | 100%   |
| `src/adapters/AaveAdapter.sol`                 | 57.80% | 60.94% | 18.52%   | 44.44% |
| `src/vault/GiveVault4626.sol`                  | 87.88% | 88.76% | 77.97%   | 81.13% |
| `src/storage/StorageLib.sol`                   | 87.37% | 86.21% | 100.00%  | 88.57% |
| `src/storage/StorageKeys.sol`                  | 0.00%  | 0.00%  | n/a      | 0.00%  |

---

## 4) Risk-Oriented Gaps (current)

### High priority

| Contract      | Gap                            | Audit relevance                                                                                                        |
| ------------- | ------------------------------ | ---------------------------------------------------------------------------------------------------------------------- |
| `AaveAdapter` | 57.80% lines / 18.52% branches | Live-pool and fork-gated behavior remains difficult to close in unit coverage; retain fork + fuzz validation emphasis. |

### Medium priority

| Contract            | Branch % | Gap description                                                        |
| ------------------- | -------- | ---------------------------------------------------------------------- |
| `CampaignVault4626` | 25.00%   | Narrow branch surface still under-covered for negative/edge paths.     |
| `PTAdapter`         | 33.33%   | Maturity/fixed-token branch paths remain partially covered.            |
| `VaultTokenBase`    | 33.33%   | Token-hook and edge paths remain partially covered.                    |
| `CampaignRegistry`  | 51.47%   | Checkpoint/stake lifecycle has improved but still has branch headroom. |

### By design / expected

- `StorageKeys` at 0% is expected (constants-only contract).
- Fork-only behavior is validated in dedicated fork suites, not denominator coverage.

---

## 5) Reproducibility

```bash
# Auditor quick check
make coverage-summary

# LCOV artifact for CI/tooling
make coverage

# Full-spectrum LCOV (includes fork/fuzz/invariant)
make coverage-full
```

> `--ir-minimum` remains required for stable coverage compilation with OZ initializers.
