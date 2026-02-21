import { beforeAll, describe } from "vitest";
import { initContext } from "./e2e/context.ts";
import { registerTestAction00EnvironmentAndCampaignLifecycle } from "./e2e/TestAction00_EnvironmentAndCampaignLifecycle.ts";
import { registerTestAction01DepositPreferenceHarvest } from "./e2e/TestAction01_DepositPreferenceHarvest.ts";
import { registerTestAction02PayoutWithdrawalInvariants } from "./e2e/TestAction02_PayoutWithdrawalInvariants.ts";
import { registerTestAction03AccessControlAndRevertPaths } from "./e2e/TestAction03_AccessControlAndRevertPaths.ts";

describe("GIVE Protocol: End-to-End Campaign Lifecycle", () => {
  beforeAll(async () => {
    await initContext();
  });

  registerTestAction00EnvironmentAndCampaignLifecycle();
  registerTestAction01DepositPreferenceHarvest();
  registerTestAction02PayoutWithdrawalInvariants();
  registerTestAction03AccessControlAndRevertPaths();
});
