# GIVE Protocol V1

**No-loss donations powered by DeFi yield.**

Users stake assets → Yield flows to charities → Principal remains safe.

---

## How It Works

1. **User deposits** USDC/DAI into a campaign vault
2. **Vault invests** 99% into DeFi protocols (Aave, Compound)
3. **Yield generated** from staking is harvested automatically
4. **Donations flow** to approved NGOs and campaigns
5. **Users withdraw** their principal anytime, 100% intact

**Governance:** Supporters vote on campaign milestones via checkpoint voting.

---

## Background

This project builds on our hackathon prototype from v0.5. We're taking the core concept and making it production-ready with proper security, upgradeability, and battle-tested patterns.

**Previous version:** [give-protocol-v0.5](https://github.com/GIVE-Labs/give-protocol-v0.5)
**Live demo:** [give-protocol-v0.vercel.app](https://give-protocol-v0.vercel.app/)

The v1 reorganized the codebase, implements UUPS upgradeability, and adds advanced features like multi-strategy management and checkpoint governance.

---

## Architecture

The protocol is built in three layers that work together:

**Layer 1: Protocol Core**
Think of this as mission control. The ACLManager handles all permissions. GiveProtocolCore coordinates everything. Three registries keep track of campaigns, yield strategies, and verified NGOs. PayoutRouter makes sure yield gets distributed correctly.

**Layer 2: Vaults**
This is where user funds actually live. Every vault is ERC-4626 compliant (standard DeFi vault interface). Campaign vaults are created on-demand by the factory. StrategyManager picks the best yield opportunities and handles rebalancing.

**Layer 3: Yield Adapters**
These are the workers. Each adapter knows how to talk to a specific DeFi protocol (Aave, Compound, etc). They're pluggable - you can swap them in and out without touching the core protocol. Some auto-compound, some track balance growth, some handle fixed maturity positions.

---

## Core Components

### **Governance**
- **ACLManager** - Centralized role management for all protocol permissions
- All contracts check roles via ACL (no standalone Ownable)

### **Registries**
- **CampaignRegistry** - Campaign submission, approval, checkpoints, governance voting
- **StrategyRegistry** - Yield strategy registration, lifecycle (Active → FadingOut → Deprecated)
- **NGORegistry** - Verified charity registration and metadata

### **Vaults**
- **GiveVault4626** - Base ERC-4626 vault with yield harvesting
- **CampaignVault4626** - Campaign-specific vault with fundraising limits
- **CampaignVaultFactory** - Deploys campaign vaults as UUPS upgradeable proxies
- **StrategyManager** - Manages multiple adapters, auto-rebalancing, performance tracking

### **Yield Distribution**
- **PayoutRouter** - Distributes harvested yield to campaigns, supporters, protocol treasury
- **Checkpoint system** - Halts payouts if governance milestones fail

### **Modules**
- **RiskModule** - Risk profiles (LTV, liquidation thresholds, caps)
- **VaultModule** - Vault configuration (cash buffer, slippage, max loss)
- **AdapterModule** - Adapter registry and validation
- **DonationModule** - Donation routing and beneficiary management
- **EmergencyModule** - Emergency pause, graceful shutdown, user withdrawals

---

## Development

### **Setup**
```bash
# Install dependencies
forge install

# Copy environment template
cp .env.example .env

# Build contracts
forge build

# Run tests
forge test

# Run specific test file
forge test --match-path test/TestContract01_ACLManager.t.sol

# Run with verbosity
forge test -vvv

# Generate gas report
forge test --gas-report
```

### **Project Structure**
```
src/
├── governance/       ACLManager
├── core/             GiveProtocolCore
├── registry/         Campaign, Strategy, NGO registries
├── vault/            GiveVault4626, CampaignVault4626, VaultTokenBase
├── factory/          CampaignVaultFactory
├── payout/           PayoutRouter
├── manager/          StrategyManager
├── adapters/         Yield adapter implementations
├── modules/          Risk, Vault, Adapter, Donation, Emergency, Synthetic
├── donation/         NGORegistry, beneficiary logic
├── types/            GiveTypes (canonical structs)
├── storage/          StorageLib, GiveStorage (Diamond storage pattern)
└── utils/            GiveErrors, Constants

script/
├── base/             BaseDeployment (shared deployment helpers)
├── Deploy01_Infrastructure.s.sol      Phase 1: Core + registries
├── Deploy02_VaultsAndAdapters.s.sol   Phase 2: Vaults + adapters
├── Deploy03_Initialize.s.sol          Phase 3: Roles + strategies
├── Upgrade.s.sol                      UUPS upgrade helper
└── operations/
    ├── AddCampaign.s.sol              Submit + approve campaign
    ├── RegisterStrategy.s.sol         Register yield strategy
    └── RegisterNGO.s.sol              Register verified NGO

test/
├── base/             Base01 → Base02 → Base03 (test environments)
├── TestContract01_ACLManager.t.sol
├── TestContract02_GiveProtocolCore.t.sol
├── TestContract03_Registries.t.sol
├── TestContract04_VaultSystem.t.sol
├── TestContract05_YieldAdapters.t.sol
└── integration/
    ├── TestAction01_CampaignLifecycle.t.sol
    └── TestAction02_MultiStrategyOperations.t.sol
```

---

## Deployment

### **Testnet Deployment (Base Sepolia)**
```bash
# Phase 1: Core infrastructure
forge script script/Deploy01_Infrastructure.s.sol \
  --rpc-url $BASE_SEPOLIA_RPC_URL \
  --private-key $PRIVATE_KEY \
  --broadcast --verify

# Phase 2: Vaults and adapters
forge script script/Deploy02_VaultsAndAdapters.s.sol \
  --rpc-url $BASE_SEPOLIA_RPC_URL \
  --private-key $PRIVATE_KEY \
  --broadcast --verify

# Phase 3: Initialize roles and strategies
forge script script/Deploy03_Initialize.s.sol \
  --rpc-url $BASE_SEPOLIA_RPC_URL \
  --private-key $PRIVATE_KEY \
  --broadcast
```

### **Add a Campaign**
```bash
# Set campaign parameters in .env
export CAMPAIGN_NAME="Climate Action Fund"
export CAMPAIGN_PAYOUT_RECIPIENT="0x..."
export CAMPAIGN_TARGET_STAKE="1000000000000"  # $1M USDC
export CAMPAIGN_MIN_STAKE="100000000"         # $100 USDC

# Submit and approve campaign
forge script script/operations/AddCampaign.s.sol \
  --rpc-url $BASE_SEPOLIA_RPC_URL \
  --private-key $PRIVATE_KEY \
  --broadcast
```

### **Upgrade Contracts**
```bash
# Upgrade ACLManager
forge script script/Upgrade.s.sol \
  --sig "upgradeACLManager()" \
  --rpc-url $BASE_SEPOLIA_RPC_URL \
  --private-key $PRIVATE_KEY \
  --broadcast --verify

# Upgrade GiveProtocolCore
forge script script/Upgrade.s.sol \
  --sig "upgradeGiveProtocolCore()" \
  --rpc-url $BASE_SEPOLIA_RPC_URL \
  --private-key $PRIVATE_KEY \
  --broadcast --verify
```

---

## Key Concepts

### **Campaign Lifecycle**
1. **Submitted** - Campaign creator submits proposal (0.005 ETH deposit)
2. **Active** - Campaign admin approves campaign
3. **Successful** - Target stake reached
4. **Failed** - Deadline passed without reaching minimum stake
5. **Completed** - Campaign ends, final payout

### **Checkpoint Governance**
- Supporters vote on milestones (proportional to stake)
- Requires quorum (configurable, e.g., 50%)
- **Failed checkpoint** → Halts payouts until resolved
- **Passed checkpoint** → Resumes yield distribution

### **Yield Adapter Kinds**
- **CompoundingValue** - Auto-compounds profit (e.g., stETH)
- **BalanceGrowth** - Balance increases over time (e.g., aTokens)
- **FixedMaturityToken** - Principal tokens with maturity date
- **ClaimableYield** - Yield queued and claimed separately
- **Manual** - Off-chain management with on-chain attestation

### **Role System**
```
ROLE_UPGRADER           Upgrade UUPS contracts
ROLE_PROTOCOL_ADMIN     Configure protocol parameters
ROLE_STRATEGY_ADMIN     Register/update strategies
ROLE_CAMPAIGN_ADMIN     Approve campaigns
ROLE_CAMPAIGN_CREATOR   Submit campaign proposals
ROLE_CAMPAIGN_CURATOR   Manage campaign metadata
ROLE_CHECKPOINT_COUNCIL Control checkpoint status transitions
VAULT_MANAGER_ROLE      Manage vault adapters and settings
```

---

## Security

### **Upgradeability**
- All core contracts use **UUPS proxy pattern** (not EIP-1167 clones)
- Upgrades require `ROLE_UPGRADER` via ACLManager
- State verification on every upgrade (storage invariants checked)

### **Emergency Controls**
- **Emergency pause** - Admin can pause deposits/harvests
- **Grace period** - 24h delay before emergency withdrawals allowed
- **User emergency withdraw** - Vault owner can withdraw shares after grace period

---

## Testing

```bash
# Full test suite
forge test

# Integration tests only
forge test --match-path test/integration/

# Specific test
forge test --match-test test_Contract01_Case01_deploymentState

# Coverage report
forge coverage

# Gas snapshot
forge snapshot
```

### **Test Organization**
- **Unit tests** - Individual contract functionality
- **Integration tests** - Full campaign lifecycle workflows
- **Base environments** - Reusable deployment fixtures

---

## License

MIT
