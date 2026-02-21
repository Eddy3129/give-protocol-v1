# GIVE Protocol — Frontend Test Suite

Last updated: 2026-02-21

## Overview

The frontend test suite validates all protocol interactions from the TypeScript/Viem layer — the same code
path a real dApp executes. It runs against any configured RPC: local Anvil, Tenderly Virtual TestNet,
BuildBear, or live Base mainnet fork.

Two test vehicles serve different purposes:

| File | Runner | Mode | Purpose |
|------|--------|------|---------|
| `frontend/test/e2e.test.ts` | Vitest | Write transactions | Full campaign lifecycle with typed assertions |
| `frontend/scripts/viem-smoke.mjs` | Node.js | Local + read-only | Multi-chain connectivity and lifecycle smoke |

### Current State vs Target

The e2e suite today covers the happy-path scaffold (4 describe blocks, ~216 lines). This document defines
the **target** — what the suite should look like for production readiness. Each section maps directly to a
Phase 6G checklist item from `CLAUDE.md`.

---

## Stack

| Tool | Version | Role |
|------|---------|------|
| `viem` | ^2.46.2 | Ethereum client (reads, writes, event decoding) |
| `vitest` | ^4.0.18 | Test runner with globals |
| `typescript` | ^5.9.3 | Full type safety |
| `tsx` | ^4.21.0 | Direct TS execution for setup scripts |
| `dotenv` | ^17.3.1 | Environment variable loading |

---

## Directory Structure

```
frontend/
├── scripts/
│   ├── viem-smoke.mjs          # Multi-mode smoke test (842 lines)
│   └── fork-smoke.sh           # Shell wrapper: anvil fork + smoke-local
├── test/
│   └── e2e.test.ts             # Vitest E2E operations suite
├── setup.ts                    # Viem client factory and ABI/address loading (71 lines)
├── vitest.config.ts            # Vitest configuration
└── package.json                # Frontend dependencies and scripts
```

---

## Configuration

### `frontend/vitest.config.ts`

```typescript
export default defineConfig({
  test: {
    environment: "node",       // No DOM — pure RPC calls
    testTimeout: 60000,        // 60s per test (fork RPCs can be slow)
    hookTimeout: 30000,        // 30s for beforeAll/afterAll
    globals: true,             // describe/it/expect available without imports
  },
});
```

### `frontend/setup.ts` — Client Factory

Initializes all Viem clients and resolves deployment artifacts before any test runs.

**RPC resolution** (priority order):
1. `TENDERLY_VIRTUAL_TESTNET_RPC`
2. `RPC_URL`
3. `BASE_RPC_URL`
4. Fallback: `http://127.0.0.1:8545`

**Clients exported**:
```typescript
publicClient   // createPublicClient  — reads, event queries, simulations
walletClient   // createWalletClient  — signed transactions (deployer/operator)
testClient     // createTestClient    — Anvil: increaseTime, mine, impersonation
```

**Deployment addresses** — loaded from JSON written by deployment scripts:
- Local: `deployments/anvil-latest.json`
- Fork/mainnet: `deployments/base-mainnet-latest.json`

Throws `Error("Deployment file not found")` if the JSON is missing — prevents tests from running
against undeployed contracts.

**ABI loading**:
```typescript
getAbi(contractName: string): Abi
// Reads from: out/<contractName>.sol/<contractName>.json (forge artifacts)
```

### Known Deployment Addresses (Anvil Latest)

These are loaded dynamically from JSON, not hardcoded in tests. Documented here for reference:

```jsonc
{
  "ACLManager":                   "0x40fEE7225bf2b982B5fe876989fE6c3100871399",
  "GiveProtocolCore":             "0xb7561a9b7C8Ac7f4Ab6A534CBA45d0643909b1a1",
  "StrategyRegistry":             "0xb906985e093483eCbf936e9150d566A809E33ad6",
  "CampaignRegistry":             "0xF4072C54bA4be297B24B07782A4B3a1A328E91a8",
  "NGORegistry":                  "0x5027Fb902Dc004e252147baDB224dfA7Fd7A0Bb9",
  "PayoutRouter":                 "0x6b001fE70a829A02591A4738195b90B4c7750540",
  "CampaignVaultFactory":         "0x2d9ff15Fb346bf63381E9E2712BB85b320c02dfe",
  "GiveVault4626Implementation":  "0x1704a4D9638E0875C1725f1DBB53dA1421F3A6d8",
  "USDCVault":                    "0x68751f19C47F3C051149b3E6c159Da5ec3821dCF",
  "USDCAddress":                  "0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913",
  "AaveUSDCAdapter":              "0xc47ea58937226A3B41F7034B8D79E7E5138502dB"
}
```

---

## E2E Test Suite (`frontend/test/e2e.test.ts`)

The Vitest suite is the definitive integration layer — it uses real contract ABIs, real transaction
signatures, and real event decoding. Every assertion maps to a specific on-chain state transition.

### Full Test Hierarchy (Target)

```
describe("GIVE Protocol: End-to-End Campaign Lifecycle")
│
├── describe("0. Environment Validation")
│   ├── it("loads all deployment addresses from JSON artifact")
│   ├── it("verifies all contract addresses have deployed code")
│   └── it("verifies chain ID matches expected network")
│
├── describe("1. Protocol State Reads")
│   ├── it("ACLManager: admin has ROLE_PROTOCOL_ADMIN")
│   ├── it("StrategyRegistry: AaveUSDCStrategy is ACTIVE")
│   ├── it("PayoutRouter: feeBps is within valid range")
│   ├── it("PayoutRouter: validAllocations returns [50, 75, 100]")
│   └── it("GiveVault4626: asset() returns USDC address")
│
├── describe("2. Campaign Lifecycle")
│   ├── it("admin submits a new campaign via CampaignRegistry")
│   ├── it("emits CampaignSubmitted with correct campaignId")
│   ├── it("admin approves the campaign")
│   ├── it("getCampaign returns status APPROVED")
│   ├── it("admin deploys a vault for the campaign")
│   ├── it("emits VaultDeployed with non-zero vault address")
│   └── it("getCampaignByVault resolves the new vault to the campaign")
│
├── describe("3. User Deposit Flow")
│   ├── it("user approves USDC for the vault")
│   ├── it("USDC.allowance(user, vault) reflects the approval")
│   ├── it("user deposits 100 USDC into the vault")
│   ├── it("emits Deposit(sender, owner, assets=100e6, shares>0)")
│   ├── it("user share balance > 0 after deposit")
│   ├── it("vault totalAssets increases by 100 USDC")
│   └── it("PayoutRouter.getUserVaultShares matches minted shares")
│
├── describe("4. Yield Preference Setup")
│   ├── it("user sets 50% allocation to campaign via setVaultPreference")
│   ├── it("emits YieldPreferenceUpdated with correct fields")
│   ├── it("getVaultPreference returns the stored preference")
│   └── it("getValidAllocations confirms 50 is a valid allocation")
│
├── describe("5. Yield Accrual and Harvest")
│   ├── it("advances time 30 days via anvil_increaseTime")
│   ├── it("vault.harvest() succeeds and emits Harvest event")
│   ├── it("Harvest event has profit > 0 (live Aave fork only)")
│   ├── it("PayoutRouter records yield: YieldRecorded event emitted")
│   └── it("getPendingYield(user, vault, USDC) > 0 after harvest")
│
├── describe("6. NGO Payout")
│   ├── it("NGO claims yield via PayoutRouter.claimYield")
│   ├── it("emits YieldClaimed with correct NGO address")
│   ├── it("NGO USDC balance increases by claimable amount")
│   └── it("getPendingYield returns 0 after claim")
│
├── describe("7. Donor Withdrawal")
│   ├── it("convertToAssets(shares) matches expected principal")
│   ├── it("user redeems all shares via GiveVault4626.redeem")
│   ├── it("emits Withdraw(sender, receiver, owner, assets, shares)")
│   ├── it("USDC returned >= deposited principal (no loss)")
│   └── it("user share balance is 0 after full redemption")
│
├── describe("8. ERC-4626 Invariants")
│   ├── it("convertToShares(convertToAssets(1e18)) ≈ 1e18 within 2 wei")
│   ├── it("convertToAssets(convertToShares(100e6)) ≈ 100e6 within 2 wei")
│   ├── it("maxDeposit(user) returns type(uint256).max or configured cap")
│   └── it("maxRedeem(user) equals current share balance")
│
├── describe("9. Access Control Boundaries")
│   ├── it("non-admin cannot call harvest()")
│   ├── it("non-admin cannot call setVaultPreference on behalf of others")
│   ├── it("non-curator cannot approve a campaign")
│   └── it("unauthorized caller cannot call CampaignRegistry.approveCampaign")
│
└── describe("10. Revert Mapping")
    ├── it("deposit(0) reverts with ZeroAmount")
    ├── it("redeem(shares+1) reverts with ERC4626ExceededMaxRedeem (0xb94abeec)")
    ├── it("deposit while paused reverts with EnforcedPause")
    ├── it("setVaultPreference with invalid % reverts with InvalidAllocation")
    └── it("approveCampaign without role reverts with AccessControlUnauthorizedAccount")
```

---

### Section 0 — Environment Validation

**Purpose**: Fail fast if deployment artifacts are missing or stale. All subsequent tests depend on this.

```typescript
describe("0. Environment Validation", () => {
  it("loads all deployment addresses from JSON artifact", async () => {
    const required = [
      "ACLManager", "GiveProtocolCore", "StrategyRegistry",
      "CampaignRegistry", "NGORegistry", "PayoutRouter",
      "CampaignVaultFactory", "USDCAddress"
    ];
    for (const key of required) {
      expect(deployments[key]).toMatch(/^0x[0-9a-fA-F]{40}$/);
      expect(deployments[key]).not.toBe("0x0000000000000000000000000000000000000000");
    }
  });

  it("verifies all contract addresses have deployed code", async () => {
    const contracts = [deployments.ACLManager, deployments.PayoutRouter, deployments.CampaignRegistry];
    for (const addr of contracts) {
      const code = await publicClient.getBytecode({ address: addr });
      expect(code).toBeDefined();
      expect(code!.length).toBeGreaterThan(2); // "0x" alone means no code
    }
  });

  it("verifies chain ID matches expected network", async () => {
    const chainId = await publicClient.getChainId();
    const expected = process.env.EXPECTED_CHAIN_ID ? Number(process.env.EXPECTED_CHAIN_ID) : 31337;
    expect(chainId).toBe(expected);
  });
});
```

---

### Section 1 — Protocol State Reads

**Purpose**: Verify protocol is correctly initialized before any write operations.

**Contract**: `ACLManager` — `hasRole(bytes32 role, address account) → bool`

Key role IDs (keccak256 hashes from deployment JSON):
- `ROLE_PROTOCOL_ADMIN`: `0x5b784347a5...`
- `ROLE_UPGRADER`: `0x8a09bc4847...`
- `ROLE_STRATEGY_ADMIN`: `0xb57297eceb...`
- `ROLE_CAMPAIGN_ADMIN`: `0xd3e32b3a2f...`

```typescript
it("ACLManager: admin has ROLE_PROTOCOL_ADMIN", async () => {
  const hasRole = await publicClient.readContract({
    address: deployments.ACLManager,
    abi: aclAbi,
    functionName: "hasRole",
    args: [deployments.ROLE_PROTOCOL_ADMIN, deployer],
  });
  expect(hasRole).toBe(true);
});
```

**Contract**: `StrategyRegistry` — `getStrategy(bytes32 strategyId) → StrategyConfig`

```typescript
it("StrategyRegistry: AaveUSDCStrategy is ACTIVE", async () => {
  const strategy = await publicClient.readContract({
    address: deployments.StrategyRegistry,
    abi: strategyRegistryAbi,
    functionName: "getStrategy",
    args: [deployments.AaveUSDCStrategyId],
  });
  // StrategyStatus.Active = 1
  expect(strategy.status).toBe(1);
  expect(strategy.adapter).not.toBe(zeroAddress);
});
```

**Contract**: `PayoutRouter`

```typescript
it("PayoutRouter: feeBps is within valid range", async () => {
  const feeBps = await publicClient.readContract({
    address: deployments.PayoutRouter,
    abi: payoutRouterAbi,
    functionName: "feeBps",
  });
  expect(feeBps).toBeGreaterThanOrEqual(0n);
  expect(feeBps).toBeLessThanOrEqual(2000n); // max 20%
});

it("PayoutRouter: validAllocations returns [50, 75, 100]", async () => {
  const allocs = await publicClient.readContract({
    address: deployments.PayoutRouter,
    abi: payoutRouterAbi,
    functionName: "getValidAllocations",
  });
  expect(Array.from(allocs)).toEqual([50, 75, 100]);
});
```

---

### Section 2 — Campaign Lifecycle

**Contract**: `CampaignRegistry`

**Function**: `submitCampaign(CampaignInput calldata input) payable`

`CampaignInput` struct fields:
```typescript
{
  proposer: Address,        // msg.sender typically
  payoutRecipient: Address, // NGO wallet receiving yield
  strategyId: Hex,          // AaveUSDCStrategyId
  metadataHash: Hex,        // keccak256 of off-chain metadata
  targetStake: bigint,      // target stake amount in USDC wei
  minStake: bigint,         // minimum stake required
  fundraisingStart: bigint, // unix timestamp
  fundraisingEnd: bigint,   // unix timestamp
}
```

**Event**: `CampaignSubmitted(bytes32 indexed id, address indexed creator)`

```typescript
it("admin submits a new campaign via CampaignRegistry", async () => {
  const hash = await walletClient.writeContract({
    address: deployments.CampaignRegistry,
    abi: campaignRegistryAbi,
    functionName: "submitCampaign",
    args: [campaignInput],
    account: deployer,
  });
  const receipt = await publicClient.waitForTransactionReceipt({ hash });
  expect(receipt.status).toBe("success");
});

it("emits CampaignSubmitted with correct campaignId", async () => {
  const logs = await publicClient.getLogs({
    address: deployments.CampaignRegistry,
    event: parseAbiItem("event CampaignSubmitted(bytes32 indexed id, address indexed creator)"),
    fromBlock: receipt.blockNumber,
    toBlock: receipt.blockNumber,
  });
  expect(logs.length).toBe(1);
  expect(logs[0].args.creator).toBe(deployer);
  campaignId = logs[0].args.id!; // capture for subsequent tests
});
```

**Function**: `approveCampaign(bytes32 campaignId, address curator)`
**Event**: `CampaignApproved(bytes32 indexed id, address indexed curator)`

```typescript
it("getCampaign returns status APPROVED", async () => {
  const campaign = await publicClient.readContract({
    address: deployments.CampaignRegistry,
    abi: campaignRegistryAbi,
    functionName: "getCampaign",
    args: [campaignId],
  });
  // CampaignStatus.Approved = 2
  expect(campaign.status).toBe(2);
  expect(campaign.curator).toBe(deployer);
});
```

**Function**: `CampaignVaultFactory.deployCampaignVault(params)`
**Event**: `VaultDeployed(address indexed vault, bytes32 indexed campaignId)`

```typescript
it("getCampaignByVault resolves the new vault to the campaign", async () => {
  const resolved = await publicClient.readContract({
    address: deployments.CampaignRegistry,
    abi: campaignRegistryAbi,
    functionName: "getCampaignByVault",
    args: [deployedVaultAddress],
  });
  expect(resolved.id).toBe(campaignId);
});
```

---

### Section 3 — User Deposit Flow

**Contract**: `ERC20 (USDC)` — `approve(address spender, uint256 amount) → bool`

**Contract**: `GiveVault4626`

**Function**: `deposit(uint256 assets, address receiver) → uint256 shares`

**Event**: `Deposit(address indexed sender, address indexed owner, uint256 assets, uint256 shares)`

```typescript
const DEPOSIT_AMOUNT = 100_000_000n; // 100 USDC (6 decimals)

it("user deposits 100 USDC into the vault", async () => {
  const sharesBefore = await publicClient.readContract({
    address: vaultAddress,
    abi: vaultAbi,
    functionName: "balanceOf",
    args: [userAddress],
  });

  const hash = await walletClient.writeContract({
    address: vaultAddress,
    abi: vaultAbi,
    functionName: "deposit",
    args: [DEPOSIT_AMOUNT, userAddress],
    account: userAddress,
  });
  const receipt = await publicClient.waitForTransactionReceipt({ hash });

  const logs = parseEventLogs({
    abi: vaultAbi,
    logs: receipt.logs,
    eventName: "Deposit",
  });
  expect(logs.length).toBe(1);
  expect(logs[0].args.assets).toBe(DEPOSIT_AMOUNT);
  expect(logs[0].args.shares).toBeGreaterThan(0n);

  const sharesAfter = await publicClient.readContract({
    address: vaultAddress,
    abi: vaultAbi,
    functionName: "balanceOf",
    args: [userAddress],
  });
  expect(sharesAfter).toBeGreaterThan(sharesBefore);
  mintedShares = sharesAfter - sharesBefore;
});

it("vault totalAssets increases by 100 USDC", async () => {
  const totalAssets = await publicClient.readContract({
    address: vaultAddress,
    abi: vaultAbi,
    functionName: "totalAssets",
  });
  expect(totalAssets).toBeGreaterThanOrEqual(DEPOSIT_AMOUNT);
});

it("PayoutRouter.getUserVaultShares matches minted shares", async () => {
  const routerShares = await publicClient.readContract({
    address: deployments.PayoutRouter,
    abi: payoutRouterAbi,
    functionName: "getUserVaultShares",
    args: [userAddress, vaultAddress],
  });
  expect(routerShares).toBe(mintedShares);
});
```

---

### Section 4 — Yield Preference Setup

**Function**: `PayoutRouter.setVaultPreference(address vault, address beneficiary, uint8 allocationPercentage)`

Valid allocation percentages: `50`, `75`, `100` (enforced by `getValidAllocations`)

**Event**: `YieldPreferenceUpdated(address indexed user, address indexed vault, bytes32 indexed campaignId, address beneficiary, uint8 allocationPercentage)`

```typescript
it("user sets 50% allocation to campaign via setVaultPreference", async () => {
  const hash = await walletClient.writeContract({
    address: deployments.PayoutRouter,
    abi: payoutRouterAbi,
    functionName: "setVaultPreference",
    args: [vaultAddress, ngoAddress, 50],
    account: userAddress,
  });
  const receipt = await publicClient.waitForTransactionReceipt({ hash });

  const logs = parseEventLogs({
    abi: payoutRouterAbi,
    logs: receipt.logs,
    eventName: "YieldPreferenceUpdated",
  });
  expect(logs[0].args.allocationPercentage).toBe(50);
  expect(logs[0].args.beneficiary).toBe(ngoAddress);
});

it("getVaultPreference returns the stored preference", async () => {
  const [prefCampaignId, prefBeneficiary, prefAllocation, active] =
    await publicClient.readContract({
      address: deployments.PayoutRouter,
      abi: payoutRouterAbi,
      functionName: "getVaultPreference",
      args: [userAddress, vaultAddress],
    });
  expect(prefBeneficiary).toBe(ngoAddress);
  expect(prefAllocation).toBe(50);
  expect(active).toBe(true);
});

it("getValidAllocations confirms 50 is a valid allocation", async () => {
  const allocs = await publicClient.readContract({
    address: deployments.PayoutRouter,
    abi: payoutRouterAbi,
    functionName: "getValidAllocations",
  });
  expect(Array.from(allocs)).toContain(50);
});
```

---

### Section 5 — Yield Accrual and Harvest

**Anvil time-travel**: `testClient.increaseTime({ seconds: 30 * 86400 })`

**Function**: `GiveVault4626.harvest() → (uint256 profit, uint256 loss)`

**Event**: `Harvest(uint256 profit, uint256 loss, uint256 donated)`

**Event**: `YieldRecorded(address indexed vault, address indexed asset, uint256 totalYield, uint256 deltaPerShare)`

```typescript
it("advances time 30 days via anvil_increaseTime", async () => {
  const blockBefore = await publicClient.getBlockNumber();
  const timestampBefore = (await publicClient.getBlock({ blockNumber: blockBefore })).timestamp;

  await testClient.increaseTime({ seconds: 30 * 24 * 60 * 60 });
  await testClient.mine({ blocks: 1 });

  const blockAfter = await publicClient.getBlockNumber();
  const timestampAfter = (await publicClient.getBlock({ blockNumber: blockAfter })).timestamp;
  expect(timestampAfter - timestampBefore).toBeGreaterThanOrEqual(30n * 86400n);
});

it("vault.harvest() succeeds and emits Harvest event", async () => {
  const hash = await walletClient.writeContract({
    address: vaultAddress,
    abi: vaultAbi,
    functionName: "harvest",
    account: operatorAddress,
  });
  const receipt = await publicClient.waitForTransactionReceipt({ hash });
  expect(receipt.status).toBe("success");

  const logs = parseEventLogs({ abi: vaultAbi, logs: receipt.logs, eventName: "Harvest" });
  expect(logs.length).toBe(1);
  harvestProfit = logs[0].args.profit;
  // Note: profit may be 0 on Anvil without live Aave — assert > 0 only on fork
});

it("PayoutRouter records yield: YieldRecorded event emitted", async () => {
  // YieldRecorded is emitted by PayoutRouter when harvest calls recordYield
  const logs = await publicClient.getLogs({
    address: deployments.PayoutRouter,
    event: parseAbiItem(
      "event YieldRecorded(address indexed vault, address indexed asset, uint256 totalYield, uint256 deltaPerShare)"
    ),
    fromBlock: harvestBlock,
    toBlock: harvestBlock,
  });
  // May be 0 events if profit == 0 (no yield on plain Anvil)
  // On Aave fork: expect exactly 1 event
  if (isFork) {
    expect(logs.length).toBe(1);
    expect(logs[0].args.totalYield).toBeGreaterThan(0n);
  }
});
```

---

### Section 6 — NGO Payout

**Function**: `PayoutRouter.claimYield(address vault, address asset) → uint256 claimed`

**Event**: `YieldClaimed(address indexed user, address indexed vault, address indexed asset, uint256 amount)`

```typescript
it("NGO claims yield via PayoutRouter.claimYield", async () => {
  const balanceBefore = await publicClient.readContract({
    address: deployments.USDCAddress,
    abi: erc20Abi,
    functionName: "balanceOf",
    args: [ngoAddress],
  });

  const hash = await walletClient.writeContract({
    address: deployments.PayoutRouter,
    abi: payoutRouterAbi,
    functionName: "claimYield",
    args: [vaultAddress, deployments.USDCAddress],
    account: ngoAddress,
  });
  const receipt = await publicClient.waitForTransactionReceipt({ hash });

  const balanceAfter = await publicClient.readContract({
    address: deployments.USDCAddress,
    abi: erc20Abi,
    functionName: "balanceOf",
    args: [ngoAddress],
  });

  if (isFork && harvestProfit > 0n) {
    expect(balanceAfter).toBeGreaterThan(balanceBefore);

    const logs = parseEventLogs({
      abi: payoutRouterAbi,
      logs: receipt.logs,
      eventName: "YieldClaimed",
    });
    expect(logs[0].args.user).toBe(ngoAddress);
    expect(logs[0].args.amount).toBeGreaterThan(0n);
  }
});

it("getPendingYield returns 0 after claim", async () => {
  const pending = await publicClient.readContract({
    address: deployments.PayoutRouter,
    abi: payoutRouterAbi,
    functionName: "getPendingYield",
    args: [ngoAddress, vaultAddress, deployments.USDCAddress],
  });
  expect(pending).toBe(0n);
});
```

---

### Section 7 — Donor Withdrawal

**Function**: `GiveVault4626.redeem(uint256 shares, address receiver, address owner) → uint256 assets`

**Event**: `Withdraw(address indexed sender, address indexed receiver, address indexed owner, uint256 assets, uint256 shares)`

```typescript
it("convertToAssets(shares) matches expected principal", async () => {
  const expectedAssets = await publicClient.readContract({
    address: vaultAddress,
    abi: vaultAbi,
    functionName: "convertToAssets",
    args: [mintedShares],
  });
  // Allow 1 wei rounding
  expect(expectedAssets).toBeGreaterThanOrEqual(DEPOSIT_AMOUNT - 1n);
});

it("user redeems all shares via GiveVault4626.redeem", async () => {
  const usdcBefore = await publicClient.readContract({
    address: deployments.USDCAddress,
    abi: erc20Abi,
    functionName: "balanceOf",
    args: [userAddress],
  });

  const hash = await walletClient.writeContract({
    address: vaultAddress,
    abi: vaultAbi,
    functionName: "redeem",
    args: [mintedShares, userAddress, userAddress],
    account: userAddress,
  });
  const receipt = await publicClient.waitForTransactionReceipt({ hash });

  const usdcAfter = await publicClient.readContract({
    address: deployments.USDCAddress,
    abi: erc20Abi,
    functionName: "balanceOf",
    args: [userAddress],
  });

  const logs = parseEventLogs({ abi: vaultAbi, logs: receipt.logs, eventName: "Withdraw" });
  expect(logs.length).toBe(1);
  expect(logs[0].args.shares).toBe(mintedShares);

  const returned = usdcAfter - usdcBefore;
  expect(returned).toBeGreaterThanOrEqual(DEPOSIT_AMOUNT); // no principal loss
});

it("user share balance is 0 after full redemption", async () => {
  const shares = await publicClient.readContract({
    address: vaultAddress,
    abi: vaultAbi,
    functionName: "balanceOf",
    args: [userAddress],
  });
  expect(shares).toBe(0n);
});
```

---

### Section 8 — ERC-4626 Invariants

These are protocol-correctness checks that should hold regardless of vault state.

```typescript
it("convertToShares(convertToAssets(1e18)) ≈ 1e18 within 2 wei", async () => {
  const assets = await publicClient.readContract({
    address: vaultAddress, abi: vaultAbi,
    functionName: "convertToAssets", args: [1_000_000_000_000_000_000n],
  });
  const sharesBack = await publicClient.readContract({
    address: vaultAddress, abi: vaultAbi,
    functionName: "convertToShares", args: [assets],
  });
  const delta = sharesBack > 1_000_000_000_000_000_000n
    ? sharesBack - 1_000_000_000_000_000_000n
    : 1_000_000_000_000_000_000n - sharesBack;
  expect(delta).toBeLessThanOrEqual(2n);
});

it("maxDeposit(user) returns type(uint256).max or configured cap", async () => {
  const max = await publicClient.readContract({
    address: vaultAddress, abi: vaultAbi,
    functionName: "maxDeposit", args: [userAddress],
  });
  expect(max).toBeGreaterThan(0n);
});

it("maxRedeem(user) equals current share balance", async () => {
  const shares = await publicClient.readContract({
    address: vaultAddress, abi: vaultAbi,
    functionName: "balanceOf", args: [userAddress],
  });
  const maxRedeem = await publicClient.readContract({
    address: vaultAddress, abi: vaultAbi,
    functionName: "maxRedeem", args: [userAddress],
  });
  expect(maxRedeem).toBe(shares);
});
```

---

### Section 9 — Access Control Boundaries

Tests that unauthorized callers receive the correct revert. Uses Viem's `simulateContract` which
throws `ContractFunctionRevertedError` on revert without sending a transaction.

```typescript
it("non-admin cannot call harvest()", async () => {
  await expect(
    publicClient.simulateContract({
      address: vaultAddress,
      abi: vaultAbi,
      functionName: "harvest",
      account: randomUser, // no ROLE_OPERATOR
    })
  ).rejects.toThrow(); // AccessControlUnauthorizedAccount
});

it("non-curator cannot approve a campaign", async () => {
  await expect(
    publicClient.simulateContract({
      address: deployments.CampaignRegistry,
      abi: campaignRegistryAbi,
      functionName: "approveCampaign",
      args: [campaignId, randomUser],
      account: randomUser,
    })
  ).rejects.toThrow();
});
```

---

### Section 10 — Revert Mapping

Exact error selectors are captured and asserted. These drive the dApp's human-readable error messages.

| Revert | Selector | Trigger Condition | User Message |
|--------|----------|-------------------|--------------|
| `ERC4626ExceededMaxRedeem` | `0xb94abeec` | Redeem more shares than owned | "Insufficient shares to redeem" |
| `ZeroAmount` | TBD from GiveErrors.sol | deposit(0) or redeem(0) | "Amount must be greater than zero" |
| `EnforcedPause` | `0xd93c0665` | Deposit/redeem while vault paused | "Vault is paused" |
| `InvalidAllocation` | TBD | setVaultPreference with % not in [50,75,100] | "Invalid allocation percentage" |
| `AccessControlUnauthorizedAccount` | `0xe2517d3f` | Missing role on restricted function | "Not authorized" |
| `InsufficientCash` | TBD | Redeem exceeds vault cash buffer | "Vault is rebalancing, try again shortly" |
| `ExcessiveLoss` | TBD | Withdrawal loss exceeds maxLossBps | "Withdrawal paused due to slippage" |
| `GracePeriodExpired` | TBD | Emergency window closed | "Emergency period ended, contact support" |

```typescript
it("deposit(0) reverts with ZeroAmount", async () => {
  await expect(
    publicClient.simulateContract({
      address: vaultAddress,
      abi: vaultAbi,
      functionName: "deposit",
      args: [0n, userAddress],
      account: userAddress,
    })
  ).rejects.toThrow(/ZeroAmount/);
});

it("redeem(shares+1) reverts with ERC4626ExceededMaxRedeem", async () => {
  const shares = await publicClient.readContract({
    address: vaultAddress, abi: vaultAbi,
    functionName: "balanceOf", args: [userAddress],
  });

  let revertData: Hex | undefined;
  try {
    await publicClient.simulateContract({
      address: vaultAddress,
      abi: vaultAbi,
      functionName: "redeem",
      args: [shares + 1n, userAddress, userAddress],
      account: userAddress,
    });
  } catch (e: unknown) {
    if (e instanceof ContractFunctionRevertedError) {
      revertData = e.data?.data;
    }
  }
  expect(revertData?.startsWith("0xb94abeec")).toBe(true);
});

it("deposit while paused reverts with EnforcedPause", async () => {
  // Admin pauses
  await walletClient.writeContract({
    address: vaultAddress, abi: vaultAbi,
    functionName: "emergencyPause",
    account: operatorAddress,
  });

  await expect(
    publicClient.simulateContract({
      address: vaultAddress, abi: vaultAbi,
      functionName: "deposit",
      args: [DEPOSIT_AMOUNT, userAddress],
      account: userAddress,
    })
  ).rejects.toThrow(/EnforcedPause|0xd93c0665/);

  // Restore — don't leak paused state into subsequent tests
  await walletClient.writeContract({
    address: vaultAddress, abi: vaultAbi,
    functionName: "resumeFromEmergency",
    account: operatorAddress,
  });
});
```

---

## Smoke Test (`frontend/scripts/viem-smoke.mjs`)

A Node.js script (not Vitest) for rapid connectivity validation. No framework overhead.
Run directly with `node frontend/scripts/viem-smoke.mjs --mode=<local|rpc>`.

### Modes

| Mode | Transactions | Deployment JSON | When to use |
|------|-------------|-----------------|-------------|
| `--mode=rpc` | None (reads only) | Not required | Verify live RPC is healthy |
| `--mode=local` | Full lifecycle | Required | Verify deployment + full flow |

### Chain Configuration

Selected via `CHAIN_CONFIG` environment variable:

| Chain | Config Path | RPC Variable |
|-------|-------------|--------------|
| Base (default) | `config/chains/base.json` | `BASE_RPC_URL` |
| Local Anvil | `config/chains/local.json` | `http://127.0.0.1:8545` |
| Arbitrum | `config/chains/arbitrum.json` | `ARBITRUM_RPC_URL` |
| Optimism | `config/chains/optimism.json` | `OPTIMISM_RPC_URL` |

---

### RPC Mode — Protocol Connectivity (13 checks)

Pure reads against a live RPC. Validates chain state and deployed external protocol contracts.

| # | Check | Contract | Function | Assertion |
|---|-------|----------|----------|-----------|
| 1 | Chain ID | — | `eth_chainId` | Matches expected (8453 for Base) |
| 2 | Block number | — | `eth_blockNumber` | > 0 |
| 3 | USDC symbol | USDC | `symbol()` | `"USDC"` |
| 4 | USDC decimals | USDC | `decimals()` | `6` |
| 5 | USDC total supply | USDC | `totalSupply()` | > 0 |
| 6 | Aave reserve data | Aave V3 Pool | `getReserveData(USDC)` | aToken address non-zero |
| 7 | Aave liquidity rate | Aave V3 Pool | `getReserveData(USDC)` | `currentLiquidityRate` > 0 |
| 8 | aUSDC supply | aUSDC token | `totalSupply()` | > 0 |
| 9 | wstETH supply | wstETH | `totalSupply()` | > 0 |
| 10 | wstETH oracle price | Aave Oracle | `getAssetPrice(wstETH)` | > 1000e8 (> $1000) |
| 11 | Pendle router | Pendle Router | `eth_getCode` | Bytecode non-empty |
| 12 | GIVE contracts exist | ACLManager, PayoutRouter | `eth_getCode` | Bytecode non-empty |
| 13 | Multi-RPC fallback | — | Primary timeout → fallback | Fallback responds correctly |

---

### Local Mode — Full Lifecycle (9 phases)

Full transaction lifecycle with assertion at each step. Requires a running Anvil or fork instance and
a valid deployment JSON.

#### Phase 0 — Setup

- Load `deployments/anvil-latest.json` or `deployments/base-mainnet-latest.json`
- Validate all required addresses are non-zero hex strings
- On plain Anvil: `MockERC20.mint(user, 1000e6)` to fund test wallets
- On fork: user wallet already holds real USDC (pre-funded by fork setup)

Assert: all contract addresses have code at their addresses.

#### Phase 1 — GiveVault4626 Reads

Verify vault is correctly initialized before any writes:

| Read | Function | Expected |
|------|----------|----------|
| `name()` | `string` | Non-empty |
| `symbol()` | `string` | Non-empty |
| `asset()` | `address` | USDC address |
| `totalAssets()` | `uint256` | ≥ 0 |
| `investPaused()` | `bool` | `false` |
| `harvestPaused()` | `bool` | `false` |
| `emergencyShutdown()` | `bool` | `false` |
| `cashBufferBps()` | `uint256` | > 0 and ≤ 10000 |
| `getCashBalance()` | `uint256` | ≥ 0 |
| `donationRouter()` | `address` | PayoutRouter address |

#### Phase 2 — PayoutRouter Reads

| Read | Function | Expected |
|------|----------|----------|
| `feeBps()` | `uint256` | ≤ 2000 |
| `feeRecipient()` | `address` | Non-zero |
| `protocolTreasury()` | `address` | Non-zero |
| `campaignRegistry()` | `address` | CampaignRegistry address |
| `getValidAllocations()` | `uint8[3]` | `[50, 75, 100]` |

#### Phase 3 — USDC Setup

On plain Anvil: call `MockERC20.mint(userWallet, 1000_000_000n)` — 1,000 USDC.
On fork: verify `USDC.balanceOf(userWallet) > 0` (wallet pre-funded by fork snapshot).

Assert: `USDC.balanceOf(userWallet) >= 100_000_000n` before proceeding.

#### Phase 4 — Approve and Deposit

```
USDC.approve(vaultAddress, 100_000_000n)           → tx success
GiveVault4626.deposit(100_000_000n, userAddress)   → tx success
```

Assertions:
- `receipt.status === "success"` for both transactions
- `Deposit` event emitted with `assets === 100_000_000n`
- `GiveVault4626.balanceOf(user) > 0` — shares minted
- `PayoutRouter.getUserVaultShares(user, vault) > 0` — router synced
- `PayoutRouter.getTotalVaultShares(vault) > 0` — total updated

#### Phase 5 — Yield Preference

```
PayoutRouter.setVaultPreference(vault, ngoAddress, 50)
```

Assertions:
- `YieldPreferenceUpdated` event emitted
- `getVaultPreference(user, vault)` returns `(campaignId, ngo, 50, true)`
- Attempting `setVaultPreference(vault, ngo, 33)` reverts (33 not in validAllocations)

#### Phase 6 — ERC-4626 Conversion Parity

Round-trip invariant check before any yield accrual:

```
convertToAssets(convertToShares(100_000_000n)) ≈ 100_000_000n  (≤ 2 wei delta)
convertToShares(convertToAssets(mintedShares)) ≈ mintedShares   (≤ 2 wei delta)
```

#### Phase 7 — Time Travel and Harvest (Anvil only)

```
testClient.increaseTime({ seconds: 30 * 86400 })
testClient.mine({ blocks: 1 })
GiveVault4626.harvest()
```

Assertions:
- Block timestamp advanced by ≥ 30 days
- `Harvest(profit, loss, donated)` event emitted (profit may be 0 on plain Anvil)
- On Aave fork: `profit > 0`

#### Phase 8 — Redeem and Verify Principal

```
GiveVault4626.redeem(mintedShares, userAddress, userAddress)
```

Assertions:
- `Withdraw` event emitted
- `assets >= DEPOSIT_AMOUNT` — no principal loss
- `GiveVault4626.balanceOf(user) === 0n` — fully redeemed
- `USDC.balanceOf(user) >= initial USDC balance` (net of approval + deposit)

#### Phase 9 — Revert Mapping

Tests each documented revert without broadcasting:

| Test | Call | Expected Error |
|------|------|----------------|
| Zero deposit | `deposit(0, user)` | `ZeroAmount` |
| Over-redeem | `redeem(shares + 1n, user, user)` | `0xb94abeec` |
| Deposit while paused | pause then `deposit(100e6, user)` | `0xd93c0665` |

---

## Running Frontend Tests

```bash
# Install dependencies (first time)
make frontend-install

# Full E2E suite on local Anvil (deploys first)
make frontend-e2e-local

# E2E against Tenderly VTN or custom RPC
make frontend-e2e-rpc

# Smoke: read-only RPC connectivity
make smoke-rpc

# Smoke: full lifecycle on local Anvil
make smoke-local

# Smoke: full lifecycle on Base fork
make smoke-fork

# Smoke: multi-chain
make smoke-arbitrum
make smoke-optimism
```

---

## Environment Variables

| Variable | Required For | Description |
|----------|-------------|-------------|
| `RPC_URL` | E2E override | Generic RPC — highest precedence after Tenderly |
| `BASE_RPC_URL` | Fork smoke, fork E2E | Base mainnet RPC or fork endpoint |
| `BASE_RPC_URL_FALLBACK` | Phase 8 (multi-RPC) | Secondary RPC for failover testing |
| `TENDERLY_VIRTUAL_TESTNET_RPC` | Tenderly VTN mode | VTN endpoint — highest precedence |
| `ARBITRUM_RPC_URL` | Multi-chain smoke | Arbitrum endpoint |
| `OPTIMISM_RPC_URL` | Multi-chain smoke | Optimism endpoint |
| `PRIVATE_KEY` | Write operations | Deployer/operator wallet private key |
| `USER_PRIVATE_KEY` | User E2E actions | Donor wallet private key |
| `EXPECTED_CHAIN_ID` | Section 0 | Override expected chain ID (default: 31337) |
| `CHAIN_CONFIG` | Smoke multi-chain | Path to chain config JSON |

---

## Contract ABIs Used in Tests

Inline ABI fragments used in the suite — not the full compiled ABI:

### ERC20 (USDC)
```typescript
const erc20Abi = parseAbi([
  "function name() view returns (string)",
  "function symbol() view returns (string)",
  "function decimals() view returns (uint8)",
  "function totalSupply() view returns (uint256)",
  "function balanceOf(address) view returns (uint256)",
  "function allowance(address owner, address spender) view returns (uint256)",
  "function approve(address spender, uint256 amount) returns (bool)",
  "function transfer(address to, uint256 amount) returns (bool)",
]);
```

### GiveVault4626
```typescript
const vaultAbi = parseAbi([
  "function name() view returns (string)",
  "function symbol() view returns (string)",
  "function asset() view returns (address)",
  "function totalAssets() view returns (uint256)",
  "function totalSupply() view returns (uint256)",
  "function balanceOf(address) view returns (uint256)",
  "function previewDeposit(uint256 assets) view returns (uint256)",
  "function previewRedeem(uint256 shares) view returns (uint256)",
  "function convertToAssets(uint256 shares) view returns (uint256)",
  "function convertToShares(uint256 assets) view returns (uint256)",
  "function maxDeposit(address) view returns (uint256)",
  "function maxRedeem(address) view returns (uint256)",
  "function getCashBalance() view returns (uint256)",
  "function getAdapterAssets() view returns (uint256)",
  "function donationRouter() view returns (address)",
  "function investPaused() view returns (bool)",
  "function harvestPaused() view returns (bool)",
  "function emergencyShutdown() view returns (bool)",
  "function cashBufferBps() view returns (uint256)",
  "function deposit(uint256 assets, address receiver) returns (uint256 shares)",
  "function redeem(uint256 shares, address receiver, address owner) returns (uint256 assets)",
  "function withdraw(uint256 assets, address receiver, address owner) returns (uint256 shares)",
  "function harvest() returns (uint256 profit, uint256 loss)",
  "function emergencyPause()",
  "function resumeFromEmergency()",
  "event Deposit(address indexed sender, address indexed owner, uint256 assets, uint256 shares)",
  "event Withdraw(address indexed sender, address indexed receiver, address indexed owner, uint256 assets, uint256 shares)",
  "event Harvest(uint256 profit, uint256 loss, uint256 donated)",
]);
```

### PayoutRouter
```typescript
const payoutRouterAbi = parseAbi([
  "function feeBps() view returns (uint256)",
  "function feeRecipient() view returns (address)",
  "function protocolTreasury() view returns (address)",
  "function campaignRegistry() view returns (address)",
  "function getValidAllocations() view returns (uint8[3])",
  "function getVaultCampaign(address vault) view returns (bytes32)",
  "function getVaultPreference(address user, address vault) view returns (bytes32, address, uint8, bool)",
  "function getUserVaultShares(address user, address vault) view returns (uint256)",
  "function getTotalVaultShares(address vault) view returns (uint256)",
  "function getPendingYield(address user, address vault, address asset) view returns (uint256)",
  "function setVaultPreference(address vault, address beneficiary, uint8 allocationPercentage)",
  "function claimYield(address vault, address asset) returns (uint256)",
  "event YieldPreferenceUpdated(address indexed user, address indexed vault, bytes32 indexed campaignId, address beneficiary, uint8 allocationPercentage)",
  "event UserSharesUpdated(address indexed user, address indexed vault, uint256 shares, uint256 totalShares)",
  "event YieldRecorded(address indexed vault, address indexed asset, uint256 totalYield, uint256 deltaPerShare)",
  "event YieldClaimed(address indexed user, address indexed vault, address indexed asset, uint256 amount)",
]);
```

### CampaignRegistry
```typescript
const campaignRegistryAbi = parseAbi([
  "function getCampaign(bytes32 campaignId) view returns (tuple(bytes32 id, address proposer, address curator, address payoutRecipient, address vault, bytes32 strategyId, bytes32 metadataHash, uint256 targetStake, uint256 minStake, uint256 totalStaked, uint64 fundraisingStart, uint64 fundraisingEnd, uint8 status, bool payoutsHalted))",
  "function getCampaignByVault(address vault) view returns (tuple(bytes32 id, address proposer, address curator, address payoutRecipient, address vault, bytes32 strategyId, bytes32 metadataHash, uint256 targetStake, uint256 minStake, uint256 totalStaked, uint64 fundraisingStart, uint64 fundraisingEnd, uint8 status, bool payoutsHalted))",
  "function submitCampaign(tuple(address proposer, address payoutRecipient, bytes32 strategyId, bytes32 metadataHash, uint256 targetStake, uint256 minStake, uint64 fundraisingStart, uint64 fundraisingEnd) input) payable",
  "function approveCampaign(bytes32 campaignId, address curator)",
  "function rejectCampaign(bytes32 campaignId, string reason)",
  "event CampaignSubmitted(bytes32 indexed id, address indexed creator)",
  "event CampaignApproved(bytes32 indexed id, address indexed curator)",
  "event CampaignRejected(bytes32 indexed id, string reason)",
]);
```

### ACLManager
```typescript
const aclAbi = parseAbi([
  "function hasRole(bytes32 role, address account) view returns (bool)",
  "function getRoleAdmin(bytes32 role) view returns (bytes32)",
]);
```

---

## Deployment Artifacts

Tests load contract addresses from JSON written by `script/operations/deploy_local_all.sh`.

Expected artifact shape:

```jsonc
{
  "chainId": 31337,
  "network": "anvil",
  "deployer": "0x...",

  // Contracts
  "ACLManager": "0x...",
  "GiveProtocolCore": "0x...",
  "StrategyRegistry": "0x...",
  "CampaignRegistry": "0x...",
  "NGORegistry": "0x...",
  "PayoutRouter": "0x...",
  "CampaignVaultFactory": "0x...",
  "GiveVault4626Implementation": "0x...",
  "USDCVault": "0x...",
  "AaveUSDCAdapter": "0x...",

  // Tokens
  "USDCAddress": "0x...",

  // Role IDs (keccak256)
  "ROLE_PROTOCOL_ADMIN": "0x...",
  "ROLE_UPGRADER": "0x...",
  "ROLE_STRATEGY_ADMIN": "0x...",
  "ROLE_CAMPAIGN_ADMIN": "0x...",
  "ROLE_CAMPAIGN_CREATOR": "0x...",
  "ROLE_CHECKPOINT_COUNCIL": "0x...",

  // Strategy/vault/risk IDs
  "AaveUSDCStrategyId": "0x...",
  "ConservativeRiskId": "0x...",
  "USDCVaultId": "0x..."
}
```

Artifacts live at:

```
deployments/
├── anvil-latest.json
├── base-mainnet-latest.json
├── arbitrum-latest.json
└── optimism-latest.json
```
