// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {Base01_DeployCore} from "../base/Base01_DeployCore.t.sol";
import {GiveTypes} from "../../src/types/GiveTypes.sol";
import {CampaignRegistry} from "../../src/registry/CampaignRegistry.sol";
import {StrategyRegistry} from "../../src/registry/StrategyRegistry.sol";
import {PayoutRouter} from "../../src/payout/PayoutRouter.sol";
import {CampaignVault4626} from "../../src/vault/CampaignVault4626.sol";
import {AaveAdapter, IPool} from "../../src/adapters/AaveAdapter.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {AaveV3BaseSepolia, AaveV3BaseSepoliaAssets} from "lib/aave-address-book/src/AaveV3BaseSepolia.sol";

contract TestFork_FullFlow is Base01_DeployCore {
    address constant AAVE_POOL = address(AaveV3BaseSepolia.POOL);
    address constant USDC = AaveV3BaseSepoliaAssets.USDC_UNDERLYING;
    address constant A_USDC = AaveV3BaseSepoliaAssets.USDC_A_TOKEN;

    CampaignVault4626 public vault;
    AaveAdapter public adapter;
    bytes32 public campaignId;
    bytes32 public strategyId;
    bytes32 public riskId;

    address public user = makeAddr("user");

    function setUp() public override {
        string memory forkUrl = vm.envOr("BASE_SEPOLIA_RPC_URL", string(""));
        if (bytes(forkUrl).length == 0) {
            vm.skip(true);
        }

        vm.createSelectFork(forkUrl);
        vm.makePersistent(USDC);
        vm.makePersistent(A_USDC);
        vm.makePersistent(AAVE_POOL);

        super.setUp();

        strategyId = keccak256("strategy.aave.usdc");
        riskId = keccak256("risk.conservative");

        // Deploy campaign vault implementation and proxy
        CampaignVault4626 vaultImpl = new CampaignVault4626();
        bytes memory initData = abi.encodeWithSelector(
            CampaignVault4626.initialize.selector,
            USDC,
            "Give Vault",
            "gvUSDC",
            admin,
            address(aclManager),
            address(vaultImpl),
            address(this)
        );
        ERC1967Proxy proxy = new ERC1967Proxy(address(vaultImpl), initData);
        vault = CampaignVault4626(payable(address(proxy)));

        adapter = new AaveAdapter(USDC, address(vault), AAVE_POOL, admin);

        vm.startPrank(strategyAdmin);
        strategyRegistry.registerStrategy(
            StrategyRegistry.StrategyInput({
                id: strategyId,
                adapter: address(adapter),
                riskTier: keccak256("LOW"),
                maxTvl: 1_000_000e6,
                metadataHash: keccak256("ipfs://test")
            })
        );
        strategyRegistry.registerStrategyVault(strategyId, address(vault));
        vm.stopPrank();

        campaignId = keccak256("campaign.test.fullflow");

        vm.deal(campaignCreator, 1 ether);
        vm.startPrank(campaignCreator);
        campaignRegistry.submitCampaign{value: 0.005 ether}(
            CampaignRegistry.CampaignInput({
                id: campaignId,
                payoutRecipient: ngo1,
                strategyId: strategyId,
                metadataHash: keccak256("test"),
                metadataCID: "test",
                targetStake: 1000e6,
                minStake: 10e6,
                fundraisingStart: uint64(block.timestamp),
                fundraisingEnd: uint64(block.timestamp + 30 days)
            })
        );
        vm.stopPrank();

        vm.startPrank(campaignAdmin);
        campaignRegistry.approveCampaign(campaignId, campaignAdmin);
        campaignRegistry.setCampaignStatus(campaignId, GiveTypes.CampaignStatus.Active);
        campaignRegistry.setCampaignVault(campaignId, address(vault), riskId);
        vm.stopPrank();

        vault.initializeCampaign(campaignId, strategyId, riskId);

        vm.startPrank(admin);
        vault.setDonationRouter(address(payoutRouter));
        vault.setActiveAdapter(adapter);
        vm.stopPrank();

        bytes32 vaultManagerRole = payoutRouter.VAULT_MANAGER_ROLE();
        vm.startPrank(admin);
        if (!aclManager.roleExists(vaultManagerRole)) {
            aclManager.createRole(vaultManagerRole, admin);
        }
        aclManager.grantRole(vaultManagerRole, campaignAdmin);
        vm.stopPrank();

        vm.startPrank(campaignAdmin);
        payoutRouter.registerCampaignVault(address(vault), campaignId);
        payoutRouter.setAuthorizedCaller(address(vault), true);
        vm.stopPrank();

        // Grant curator role to campaignAdmin for stake tracking
        vm.startPrank(admin);
        aclManager.grantRole(aclManager.campaignCuratorRole(), campaignAdmin);
        vm.stopPrank();
    }

    function test_FullFlow_DepositToVoting() public {
        uint256 amount = 100e6;
        deal(USDC, user, amount);

        vm.startPrank(user);
        IERC20(USDC).approve(address(vault), amount);
        vault.deposit(amount, user);
        vm.stopPrank();

        vm.prank(campaignAdmin);
        campaignRegistry.recordStakeDeposit(campaignId, user, amount);

        GiveTypes.SupporterStake memory stake = campaignRegistry.getStakePosition(campaignId, user);
        assertGt(stake.shares, 0, "stake not recorded");

        vm.warp(block.timestamp + 2 hours);

        uint256 simulatedYield = 5e6;
        _simulateAaveYield(simulatedYield);

        uint256 ngoBefore = IERC20(USDC).balanceOf(ngo1);
        (uint256 profit, uint256 loss) = vault.harvest();
        assertGt(profit, 0, "profit not realized");
        assertEq(loss, 0, "unexpected loss");
        assertGt(IERC20(USDC).balanceOf(ngo1), ngoBefore, "NGO did not receive funds");

        vm.startPrank(campaignAdmin);
        CampaignRegistry.CheckpointInput memory input = CampaignRegistry.CheckpointInput({
            windowStart: uint64(block.timestamp + 1 hours),
            windowEnd: uint64(block.timestamp + 2 days),
            executionDeadline: uint64(block.timestamp + 3 days),
            quorumBps: 1000
        });
        uint256 cpIndex = campaignRegistry.scheduleCheckpoint(campaignId, input);
        vm.stopPrank();

        vm.prank(checkpointCouncil);
        campaignRegistry.updateCheckpointStatus(campaignId, cpIndex, GiveTypes.CheckpointStatus.Voting);

        vm.warp(input.windowStart + 1);
        vm.prank(user);
        campaignRegistry.voteOnCheckpoint(campaignId, cpIndex, true);

        vm.warp(input.windowEnd + 1);
        vm.prank(campaignAdmin);
        campaignRegistry.finalizeCheckpoint(campaignId, cpIndex);

        (,,, uint16 quorumBps, GiveTypes.CheckpointStatus status, uint256 eligibleStake) =
            campaignRegistry.getCheckpoint(campaignId, cpIndex);

        assertEq(quorumBps, 1000, "quorum mismatch");
        assertEq(uint8(status), uint8(GiveTypes.CheckpointStatus.Succeeded), "checkpoint failed");
        assertGt(eligibleStake, 0, "eligible stake missing");
    }

    function _simulateAaveYield(uint256 amount) internal {
        if (amount == 0) return;

        deal(USDC, address(adapter), amount);

        vm.startPrank(address(adapter));
        IERC20(USDC).approve(AAVE_POOL, amount);
        IPool(AAVE_POOL).supply(USDC, amount, address(adapter), 0);
        vm.stopPrank();
    }
}
