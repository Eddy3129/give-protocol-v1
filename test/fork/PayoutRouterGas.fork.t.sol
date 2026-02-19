// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {ForkBase} from "./ForkBase.t.sol";
import {ForkAddresses} from "./ForkAddresses.sol";
import {PayoutRouter} from "../../src/payout/PayoutRouter.sol";
import {MockERC20} from "../../src/mocks/MockERC20.sol";
import {GiveTypes} from "../../src/types/GiveTypes.sol";

// ── Minimal mocks ────────────────────────────────────────────────────────────

contract GasMockACL {
    function hasRole(bytes32, address) external pure returns (bool) { return false; }
}

contract GasMockCampaignRegistry {
    address public immutable payoutRecipient;
    constructor(address r) { payoutRecipient = r; }
    function getCampaign(bytes32 id) external view returns (GiveTypes.CampaignConfig memory cfg) {
        uint256[49] memory gap;
        cfg.id = id; cfg.payoutRecipient = payoutRecipient;
        cfg.status = GiveTypes.CampaignStatus.Active; cfg.exists = true; cfg.__gap = gap;
    }
}

/// @title PayoutRouterGasForkTest
/// @notice Validates that recordYield and claimYield gas costs are O(1) —
///         independent of the number of depositors in the vault.
///
///         These tests do NOT require a live Aave connection; a fork is used only
///         to ensure identical EVM context to mainnet. The actual yield is simulated
///         with MockERC20.
///
///         If either function's gas scales with depositor count, the accumulator
///         model has regressed to a loop-based path — file as critical.
contract PayoutRouterGasForkTest is ForkBase {
    PayoutRouter internal router;
    MockERC20    internal asset;

    address internal admin;
    address internal ngo;
    address internal vaultAddr; // this contract acts as vault

    bytes32 internal constant CAMPAIGN_ID = keccak256("gas_campaign");

    // Gas ceilings confirmed against accumulator implementation
    uint256 internal constant RECORD_YIELD_GAS_CEILING  = 200_000;
    uint256 internal constant CLAIM_YIELD_GAS_CEILING   = 350_000;

    // Depositor counts to sweep — gas must be flat across all
    uint256[4] internal DEPOSITOR_COUNTS = [uint256(10), 50, 100, 200];

    function setUp() public override {
        super.setUp();
        if (!_forkActive) return;

        admin     = makeAddr("gas_admin");
        ngo       = makeAddr("gas_ngo");
        vaultAddr = address(this); // this contract is the authorized vault

        asset = new MockERC20("USDC", "USDC", 6);

        GasMockACL acl = new GasMockACL();
        GasMockCampaignRegistry registry = new GasMockCampaignRegistry(ngo);

        router = new PayoutRouter();
        vm.startPrank(admin);
        router.initialize(admin, address(acl), address(registry), admin, admin, 250);
        router.grantRole(router.VAULT_MANAGER_ROLE(), admin);
        router.registerCampaignVault(vaultAddr, CAMPAIGN_ID);
        router.setAuthorizedCaller(vaultAddr, true);
        vm.stopPrank();
    }

    // ── Helpers ───────────────────────────────────────────────────────

    /// @dev Register N depositors with equal shares and record one yield round.
    function _setupDepositors(uint256 n) internal returns (address[] memory actors) {
        actors = new address[](n);
        uint256 sharesEach = 1_000e6;
        for (uint256 i = 0; i < n; i++) {
            actors[i] = makeAddr(string(abi.encodePacked("gas_actor_", i)));
            router.updateUserShares(actors[i], sharesEach);
        }
    }

    function _mintAndTransferYield(uint256 amount) internal {
        asset.mint(address(this), amount);
        asset.transfer(address(router), amount);
    }

    // ── Tests ─────────────────────────────────────────────────────────

    /// @notice recordYield gas must not grow with depositor count.
    ///         O(1) accumulator: one storage write + one event per call.
    function test_recordYield_gas_is_flat() public requiresFork {
        uint256 yieldAmount = 1_000e6;
        uint256[4] memory gasUsed;

        for (uint256 j = 0; j < DEPOSITOR_COUNTS.length; j++) {
            uint256 n = DEPOSITOR_COUNTS[j];

            // Fresh router state per run
            PayoutRouter freshRouter = new PayoutRouter();
            GasMockACL acl = new GasMockACL();
            GasMockCampaignRegistry registry = new GasMockCampaignRegistry(ngo);
            vm.startPrank(admin);
            freshRouter.initialize(admin, address(acl), address(registry), admin, admin, 250);
            freshRouter.grantRole(freshRouter.VAULT_MANAGER_ROLE(), admin);
            freshRouter.registerCampaignVault(address(this), CAMPAIGN_ID);
            freshRouter.setAuthorizedCaller(address(this), true);
            vm.stopPrank();

            for (uint256 i = 0; i < n; i++) {
                freshRouter.updateUserShares(makeAddr(string(abi.encodePacked("r_actor_", i))), 1_000e6);
            }

            asset.mint(address(this), yieldAmount);
            asset.transfer(address(freshRouter), yieldAmount);

            uint256 gasBefore = gasleft();
            freshRouter.recordYield(address(asset), yieldAmount);
            gasUsed[j] = gasBefore - gasleft();

            assertLt(
                gasUsed[j],
                RECORD_YIELD_GAS_CEILING,
                string(abi.encodePacked("recordYield gas exceeded ceiling at n=", vm.toString(n)))
            );

            emit log_named_uint(
                string(abi.encodePacked("recordYield gas (n=", vm.toString(n), ")")),
                gasUsed[j]
            );
        }

        // Confirm flatness: max - min across counts must be within 10%
        uint256 minGas = gasUsed[0];
        uint256 maxGas = gasUsed[0];
        for (uint256 j = 1; j < 4; j++) {
            if (gasUsed[j] < minGas) minGas = gasUsed[j];
            if (gasUsed[j] > maxGas) maxGas = gasUsed[j];
        }
        assertLe(
            maxGas - minGas,
            minGas / 10, // within 10% spread
            "recordYield gas is not flat across depositor counts - accumulator may have regressed"
        );
    }

    /// @notice claimYield gas for one user must not grow with total depositor count.
    ///         Only that user's debt/pending is read — no loop over all shareholders.
    function test_claimYield_gas_independent_of_depositor_count() public requiresFork {
        uint256 yieldAmount = 1_000e6;
        uint256[4] memory gasUsed;

        for (uint256 j = 0; j < DEPOSITOR_COUNTS.length; j++) {
            uint256 n = DEPOSITOR_COUNTS[j];

            PayoutRouter freshRouter = new PayoutRouter();
            GasMockACL acl = new GasMockACL();
            GasMockCampaignRegistry registry = new GasMockCampaignRegistry(ngo);
            vm.startPrank(admin);
            freshRouter.initialize(admin, address(acl), address(registry), admin, admin, 250);
            freshRouter.grantRole(freshRouter.VAULT_MANAGER_ROLE(), admin);
            freshRouter.registerCampaignVault(address(this), CAMPAIGN_ID);
            freshRouter.setAuthorizedCaller(address(this), true);
            vm.stopPrank();

            address claimer = makeAddr("claimer");
            freshRouter.updateUserShares(claimer, 1_000e6);
            for (uint256 i = 0; i < n - 1; i++) {
                freshRouter.updateUserShares(
                    makeAddr(string(abi.encodePacked("c_actor_", i))), 1_000e6
                );
            }

            asset.mint(address(this), yieldAmount);
            asset.transfer(address(freshRouter), yieldAmount);
            freshRouter.recordYield(address(asset), yieldAmount);

            uint256 gasBefore = gasleft();
            vm.prank(claimer);
            freshRouter.claimYield(address(this), address(asset));
            gasUsed[j] = gasBefore - gasleft();

            assertLt(
                gasUsed[j],
                CLAIM_YIELD_GAS_CEILING,
                string(abi.encodePacked("claimYield gas exceeded ceiling at n=", vm.toString(n)))
            );

            emit log_named_uint(
                string(abi.encodePacked("claimYield gas (n=", vm.toString(n), ")")),
                gasUsed[j]
            );
        }

        // Confirm flatness
        uint256 minGas = gasUsed[0];
        uint256 maxGas = gasUsed[0];
        for (uint256 j = 1; j < 4; j++) {
            if (gasUsed[j] < minGas) minGas = gasUsed[j];
            if (gasUsed[j] > maxGas) maxGas = gasUsed[j];
        }
        assertLe(
            maxGas - minGas,
            minGas / 4,
            "claimYield gas is not flat across depositor counts - loop regression detected"
        );
    }
}
