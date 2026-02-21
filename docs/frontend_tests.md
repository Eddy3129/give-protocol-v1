# GIVE Protocol — Frontend Test Suite

Last updated: 2026-02-21

## Purpose

This suite validates protocol behavior through the same Viem write/read paths used by the dApp.
It is the release-gate integration layer for campaign lifecycle, deposits, harvest, payouts,
withdrawals, access-control, and revert mapping.

## Current Status

- Strict E2E passes on live-like BuildBear context (`56/56`)
- Local + RPC smoke paths remain available (`viem-smoke.mjs`)
- E2E is now strict-only and enforces explicit deployment artifact selection (`DEPLOYMENT_NETWORK` or `DEPLOYMENTS_FILE`)
- Newly deployed campaign vaults are operationalized in-test (router wiring + vault-bound adapter activation)

## What We Learned (from failures)

1. **Role admin model matters more than role membership**
   - `grantRole` failed when caller was not the role admin/super-admin.
2. **Factory needs canonical lifecycle roles**
   - `CampaignVaultFactory` requires campaign/strategy permissions for end-to-end vault lifecycle.
3. **Wrong deployment artifact selection can silently poison tests**
   - BuildBear often reports chain-like behavior that can resolve to wrong `*-latest.json` if network selection is implicit.
4. **Adapter is vault-bound**
   - Fresh campaign vaults cannot reuse adapter assumptions from base vault; they need a compatible active adapter instance.
5. **Harvest access expectation was incorrect**
   - Current contract behavior allows non-admin harvest execution path (permissionless), so tests must assert that behavior.

## Production-Standard E2E Architecture

### Test Entry

- `frontend/test/e2e.test.ts`
  - Initializes context once (`beforeAll -> initContext()`)
  - Registers action modules in order

### Action Modules

- `frontend/test/e2e/TestAction00_EnvironmentAndCampaignLifecycle.ts`
  - Environment validation
  - Protocol state reads
  - Campaign submit/approve/deploy
  - Operationalizes new campaign vault:
    - ensure donation router
    - deploy vault-bound `AaveAdapter` when needed
    - set active adapter
- `frontend/test/e2e/TestAction01_DepositPreferenceHarvest.ts`
  - Funding checks + deposit path
  - Preference setup
  - Harvest path with diagnostics and strict assertions
- `frontend/test/e2e/TestAction02_PayoutWithdrawalInvariants.ts`
  - NGO claim flow
  - Redeem flow
  - ERC-4626 invariants
- `frontend/test/e2e/TestAction03_AccessControlAndRevertPaths.ts`
  - Access boundaries
  - Revert selector coverage and pause/resume checks
  - Section completion checkpoint summary

### Shared Runtime Context

- `frontend/test/e2e/context.ts`
  - Strict-only runtime (no non-strict fallback path)
  - Deployment/address loading from `frontend/setup.ts`
  - Signer setup for admin/user/ngo/outsider accounts
  - Error classification helpers (`rpc`, `contract-revert`, `viem`, `unknown`)

## Required Environment Configuration (First Step)

Set these in `.env` before E2E runs:

- `PRIVATE_KEY`
- `USER_PRIVATE_KEY`
- `NGO_PRIVATE_KEY`
- `OUTSIDER_PRIVATE_KEY`
- `ADMIN_ADDRESS`
- `PROTOCOL_ADMIN_ADDRESS`
- `STRATEGY_ADMIN_ADDRESS`
- `CAMPAIGN_ADMIN_ADDRESS`
- `RPC_URL` (or `BASE_RPC_URL`)
- `DEPLOYMENT_NETWORK` (recommended) or `DEPLOYMENTS_FILE`
- `AAVE_POOL_ADDRESS`

Reference template: `.env.example`

## Recommended Commands

### Primary command

```bash
make vitest
```

### Local flow (explicit override)

```bash
make deploy-local
make frontend-e2e RPC_URL=http://127.0.0.1:8545 DEPLOYMENT_NETWORK=anvil
```

### Live-like flow (BuildBear / Tenderly VTN)

```bash
make frontend-e2e \
  RPC_URL=https://rpc.buildbear.io/<env> \
  DEPLOYMENT_NETWORK=anvil
```

### Direct frontend command (equivalent)

```bash
RPC_URL=... DEPLOYMENT_NETWORK=anvil FRONTEND_E2E_STRICT=true pnpm --dir frontend test:e2e
```

## Strict Mode Policy

Strict-only runtime is intended for release readiness and CI-quality runs:

- No implicit deployment artifact fallback
- No silent role/funding assumptions
- Fail on missing critical wiring/configuration
- Preserve deterministic diagnostics (tx hash + classified error source)

## Deployment Flow Tie-In

The deployment scripts must guarantee post-deploy invariants consumed by E2E:

- canonical roles exist and are granted to operational actors
- campaign vault factory has required lifecycle roles
- base vault is wired to `PayoutRouter` and authorized caller controls are set
- strategy + adapter initialization is deterministic

See:

- `script/Deploy01_Infrastructure.s.sol`
- `script/Deploy02_VaultsAndAdapters.s.sol`
- `script/Deploy03_Initialize.s.sol`

## Release Checklist (Frontend E2E)

- `make vitest` passes with valid `.env` and deployment artifact selection
- no skipped sections in strict mode
- campaign vault deploy path includes active adapter and router wiring
- access-control assertions match implemented contract permissions
- revert mapping section remains green for known selectors
