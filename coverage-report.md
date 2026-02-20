# Coverage Report

Generated: 2026-02-20 (Update M)
Command: `forge coverage --ir-minimum --report summary --no-match-path "test/fork/**:test/fuzz/**:test/invariant/**"`
Scope: unit + integration tests (fork/fuzz/invariant excluded)
Tests run: 428 passed, 0 failed

> Note: `[profile.default]` now excludes fork/fuzz/invariant via `no_match_path`.
> `forge test` runs unit + integration only. Use `FOUNDRY_PROFILE=full/fork/fuzz/invariant`
> for those suites.

---

## Overall (all files)

| Metric     | Coverage           |
| ---------- | ------------------ |
| Lines      | 60.43% (2416/3998) |
| Statements | 61.00% (2550/4180) |
| Branches   | 49.23% (286/581)   |
| Functions  | 62.62% (407/650)   |

Note: Total includes scripts at 0%. For src/ contracts only (production code), see detailed table below.

Branch coverage is the weakest signal — many remaining branches represent ETH wrapper paths
(require fork+WETH), live Aave pool calls, and upgrade authorization (require live ACL state).

---

## Source contracts (`src/`)

| Contract                                       | Lines  | Stmts  | Branches | Funcs  | Notes                                    |
| ---------------------------------------------- | ------ | ------ | -------- | ------ | ---------------------------------------- |
| `src/governance/ACLManager.sol`                | 99.25% | 97.87% | 88.46%   | 100%   | Well covered                             |
| `src/core/GiveProtocolCore.sol`                | 100%   | 100%   | 100%     | 100%   | Full coverage                            |
| `src/adapters/base/AdapterBase.sol`            | 100%   | 100%   | 100%     | 100%   | Full coverage                            |
| `src/modules/AdapterModule.sol`                | 100%   | 100%   | 100%     | 100%   | Full coverage                            |
| `src/modules/DonationModule.sol`               | 100%   | 100%   | 100%     | 100%   | Full coverage                            |
| `src/modules/SyntheticModule.sol`              | 100%   | 100%   | 100%     | 100%   | Full coverage                            |
| `src/modules/VaultModule.sol`                  | 100%   | 100%   | 100%     | 100%   | Full coverage                            |
| `src/utils/ACLShim.sol`                        | 100%   | 100%   | 100%     | 100%   | Full coverage (was 30%)                  |
| `src/adapters/kinds/ClaimableYieldAdapter.sol` | 100%   | 100%   | 100%     | 100%   | Full coverage (was 44%)                  |
| `src/registry/StrategyRegistry.sol`            | 94.38% | 94.59% | 84.21%   | 100%   | Good                                     |
| `src/adapters/kinds/PendleAdapter.sol`         | 94.23% | 92.54% | 70.00%   | 83.33% | Good                                     |
| `src/adapters/kinds/CompoundingAdapter.sol`    | 93.94% | 87.88% | 57.14%   | 100%   | Good                                     |
| `src/adapters/kinds/ManualManageAdapter.sol`   | 93.51% | 94.74% | 89.47%   | 90.91% | Excellent (+44pp lines)                  |
| `src/vault/CampaignVault4626.sol`              | 96.00% | 92.00% | 33.33%   | 100%   | Good                                     |
| `src/modules/EmergencyModule.sol`              | 97.06% | 88.24% | 63.64%   | 100%   | Good                                     |
| `src/donation/NGORegistry.sol`                 | 90.27% | 81.45% | 52.63%   | 95.00% | High-priority branch gaps closed         |
| `src/factory/CampaignVaultFactory.sol`         | 96.61% | 96.20% | 92.31%   | 100%   | Fail-leg and guard branches now covered  |
| `src/adapters/kinds/GrowthAdapter.sol`         | 92.00% | 95.45% | 60.00%   | 83.33% | Edge branches covered                    |
| `src/adapters/kinds/PTAdapter.sol`             | 84.78% | 82.35% | 33.33%   | 75.00% | Branch gaps                              |
| `src/payout/PayoutRouter.sol`                  | 88.72% | 88.85% | 87.80%   | 88.10% | Target exceeded in Update M              |
| `src/manager/StrategyManager.sol`              | 77.59% | 76.19% | 72.73%   | 77.27% | Some paths uncovered                     |
| `src/modules/RiskModule.sol`                   | 73.58% | 75.76% | 66.67%   | 80.00% | Validation-matrix branches improved      |
| `src/registry/CampaignRegistry.sol`            | 85.96% | 83.33% | 50.00%   | 84.62% | Stake/checkpoint state branches expanded |
| `src/vault/VaultTokenBase.sol`                 | 63.64% | 58.33% | 25.00%   | 80.00% | Some paths uncovered                     |
| `src/storage/GiveStorage.sol`                  | 66.67% | 50.00% | 100%     | 100%   | Indirect coverage                        |
| `src/adapters/AaveAdapter.sol`                 | 57.80% | 60.94% | 18.52%   | 44.44% | Fork-only paths                          |
| `src/vault/GiveVault4626.sol`                  | 78.79% | 81.07% | 83.05%   | 71.70% | Target exceeded in Update M              |
| `src/storage/StorageLib.sol`                   | 87.37% | 86.21% | 100.00%  | 88.57% | Dedicated accessor/revert suite added    |
| `src/storage/StorageKeys.sol`                  | 0.00%  | 0.00%  | n/a      | 0.00%  | Pure constants — expected                |

> `AaveAdapter` and `GiveVault4626` ETH paths are primarily exercised by fork tests.
> `StorageLib` now has explicit unit coverage.

---

## Coverage gaps to address

### Remaining high priority (src contracts, <65% lines)

| Contract      | Gap    | Suggested action                                      |
| ------------- | ------ | ----------------------------------------------------- |
| `AaveAdapter` | 57.80% | Keep fork/fuzz closure for live-pool-only paths       |
| `StorageKeys` | 0.00%  | Pure constants; no action needed (expected by design) |

### Medium priority (branch coverage <35%)

| Contract            | Branch % | Gap description                                         |
| ------------------- | -------- | ------------------------------------------------------- |
| `VaultTokenBase`    | 25.0%    | Internal token hooks and edge paths still under-covered |
| `CampaignVault4626` | 33.3%    | Narrow branch surface; add targeted negative-path tests |
| `PTAdapter`         | 33.3%    | PT-specific branch paths remain                         |

### Low priority (fork-gated or by design)

- `AaveAdapter` — 50%+ of functions require live Aave pool; covered by fork suite
- `GiveVault4626` ETH paths — require WETH; covered by `ForkTest04_DepositETH.fork.t.sol`
- `StorageKeys` — pure constant definitions, 0% is expected
- `StorageLib` — now explicitly covered by `TestContract20_StorageLib.t.sol`

---

## Notable improvements (Update M)

| Contract                | Measurement      | Previous  | Current         | Δ                  |
| ----------------------- | ---------------- | --------- | --------------- | ------------------ |
| `GiveVault4626`         | Lines / Branches | 57% / 34% | **79% / 83%**   | **+22pp / +49pp**  |
| `PayoutRouter`          | Lines / Branches | 80% / 37% | **89% / 88%**   | **+9pp / +51pp**   |
| `ManualManageAdapter`   | Lines / Branches | 49% / 21% | **93% / 89%**   | **+44pp / +68pp**  |
| `ClaimableYieldAdapter` | Lines / Branches | 44% / 14% | **100% / 100%** | **+56pp / +86pp**  |
| `ACLShim`               | Lines / Branches | 30% / 0%  | **100% / 100%** | **+70pp / +100pp** |
| `StorageLib`            | Lines / Branches | 56% / 0%  | **87% / 100%**  | **+31pp / +100pp** |
| `CampaignRegistry`      | Lines / Branches | 67% / 27% | **86% / 50%**   | **+19pp / +23pp**  |
| `CampaignVaultFactory`  | Lines / Branches | 86% / 23% | **97% / 92%**   | **+11pp / +69pp**  |
| `NGORegistry`           | Lines / Branches | 87% / 26% | **90% / 53%**   | **+3pp / +27pp**   |

> Major gains are now driven by TestContract14–21 plus extended branch suites in
> `TestContract17_PayoutRouterBranches.t.sol` and `TestContract18_GiveVault4626Branches.t.sol`, including dedicated branch coverage for
> CampaignRegistry, StorageLib, and explicit UUPS `ROLE_UPGRADER` authorization paths.

---

## How to run

```bash
# Unit + integration coverage (fast, no RPC needed)
FOUNDRY_PROFILE=coverage forge coverage --ir-minimum --report summary \
  --no-match-path "test/fork/**:test/fuzz/**:test/invariant/**"

# LCOV artifact
FOUNDRY_PROFILE=coverage forge coverage --ir-minimum --report lcov \
  --no-match-path "test/fork/**:test/fuzz/**:test/invariant/**"

# npm shortcuts
npm run coverage          # lcov report → lcov.info
npm run coverage:summary  # terminal table

# Fast unit-only run (no coverage instrumentation)
npm run test:fast

# Full test suite (all suites, no coverage)
FOUNDRY_PROFILE=full forge test

# Fork-only tests
FOUNDRY_PROFILE=fork forge test --fork-url $BASE_RPC_URL
```

> `--ir-minimum` is required permanently: OZ's `__ERC20_init` uses inline assembly that
> hits the 16-slot stack limit with `optimizer=false, via_ir=false`. This flag stays.

---

**Report updated on 2026-02-20 (Update M)**  
**Test count increased:** 408 → 428 tests (+20 new test cases)  
**Key improvements:**

- `GiveVault4626`: 57% → **79% lines** (+22pp), 34% → **83% branches** (+49pp)
- `PayoutRouter`: 80% → **89% lines** (+9pp), 37% → **88% branches** (+51pp)
- `ManualManageAdapter`: 49% → **93% lines** (+44pp), 21% → **89% branches** (+68pp)
- `StorageLib`: 56% → **87% lines** (+31pp), 0% → **100% branches** (+100pp)
- `CampaignVaultFactory`: 86% → **97% lines** (+11pp), 23% → **92% branches** (+69pp)
