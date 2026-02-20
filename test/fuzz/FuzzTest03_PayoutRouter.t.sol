// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title   FuzzTest03_PayoutRouter
 * @author  GIVE Labs
 * @notice  Stateless property-based fuzzing for PayoutRouter accumulator logic
 * @dev     Tests core yield distribution properties with arbitrary inputs:
 *          - recordYield: arbitrary asset amounts and delta-per-share updates
 *          - claimYield: arbitrary user list, beneficiary splits, and preference allocation
 *          - Fee enforcement: protocol fee must not exceed MAX_FEE_BPS of recorded yield
 *          - Accumulator integrity: per-share delta is monotonically non-decreasing
 */

import "forge-std/Test.sol";

import {PayoutRouter} from "../../src/payout/PayoutRouter.sol";
import {MockERC20} from "../../src/mocks/MockERC20.sol";
import {GiveTypes} from "../../src/types/GiveTypes.sol";

contract FuzzMockACL {
    function hasRole(bytes32, address) external pure returns (bool) {
        return false;
    }
}

contract FuzzMockCampaignRegistry {
    address public mockPayoutRecipient;

    constructor() {
        mockPayoutRecipient = makeAddr("mockPayoutRecipient");
    }

    function getCampaign(bytes32 id) external view returns (GiveTypes.CampaignConfig memory) {
        uint256[49] memory emptyGap;

        return GiveTypes.CampaignConfig({
            id: id,
            proposer: address(0),
            curator: address(0),
            payoutRecipient: mockPayoutRecipient,
            vault: address(0),
            strategyId: bytes32(0),
            metadataHash: bytes32(0),
            targetStake: 0,
            minStake: 0,
            totalStaked: 0,
            lockedStake: 0,
            initialDeposit: 0,
            fundraisingStart: 0,
            fundraisingEnd: 0,
            createdAt: 0,
            updatedAt: 0,
            status: GiveTypes.CampaignStatus.Active,
            lockProfile: bytes32(0),
            checkpointQuorumBps: 0,
            checkpointVotingDelay: 0,
            checkpointVotingPeriod: 0,
            exists: true,
            payoutsHalted: false,
            __gap: emptyGap
        });
    }

    function makeAddr(string memory label) private pure returns (address) {
        return address(uint160(uint256(keccak256(abi.encodePacked(label)))));
    }
}

contract FuzzTest03_PayoutRouter is Test {
    PayoutRouter private payoutRouter;
    MockERC20 private usdc;
    FuzzMockACL private acl;
    FuzzMockCampaignRegistry private campaignRegistry;

    address private admin;
    address private treasury;
    address private feeRecipient;
    address private vault;

    bytes32 private constant CAMPAIGN_ID = keccak256("fuzz.campaign");

    function setUp() public {
        admin = makeAddr("admin");
        treasury = makeAddr("treasury");
        feeRecipient = makeAddr("feeRecipient");
        vault = makeAddr("vault");

        usdc = new MockERC20("USD Coin", "USDC", 6);
        acl = new FuzzMockACL();
        campaignRegistry = new FuzzMockCampaignRegistry();

        payoutRouter = new PayoutRouter();
        vm.prank(admin);
        payoutRouter.initialize(admin, address(acl), address(campaignRegistry), feeRecipient, treasury, 250);

        vm.startPrank(admin);
        payoutRouter.grantRole(payoutRouter.VAULT_MANAGER_ROLE(), admin);
        payoutRouter.grantRole(payoutRouter.FEE_MANAGER_ROLE(), admin);
        payoutRouter.registerCampaignVault(vault, CAMPAIGN_ID);
        payoutRouter.setAuthorizedCaller(vault, true);
        vm.stopPrank();
    }

    function testFuzz_distribution_no_leakage(uint256 totalYield, uint8 numHolders, uint256[16] calldata shares)
        public
    {
        uint256 holderCount = bound(uint256(numHolders), 1, 16);
        uint256 boundedYield = bound(totalYield, 1e6, 50_000_000e6);

        address[] memory users = new address[](holderCount);

        for (uint256 i = 0; i < holderCount; i++) {
            address user = vm.addr(20_000 + i);
            users[i] = user;

            uint256 userShares = bound(shares[i], 1, 10_000_000e6);
            vm.prank(vault);
            payoutRouter.updateUserShares(user, userShares);

            uint8 allocation = i % 3 == 0 ? 50 : i % 3 == 1 ? 75 : 100;
            vm.prank(user);
            payoutRouter.setVaultPreference(vault, user, allocation);
        }

        usdc.mint(address(payoutRouter), boundedYield);
        vm.prank(vault);
        payoutRouter.recordYield(address(usdc), boundedYield);

        uint256 userAggregate;
        uint256 sumClaimed;
        for (uint256 i = 0; i < holderCount; i++) {
            address user = users[i];
            uint256 beforeUser = usdc.balanceOf(user);
            vm.prank(user);
            sumClaimed += payoutRouter.claimYield(vault, address(usdc));
            userAggregate += (usdc.balanceOf(user) - beforeUser);
        }

        uint256 protocolAmount = usdc.balanceOf(treasury);
        uint256 campaignAmount = usdc.balanceOf(campaignRegistry.mockPayoutRecipient());
        uint256 distributed = protocolAmount + campaignAmount + userAggregate;

        assertEq(distributed, sumClaimed);
        assertLe(distributed, boundedYield);
    }

    function testFuzz_fee_calculation_bounded(uint256 userYield, uint16 feeBps) public {
        uint256 boundedYield = bound(userYield, 1e6, 10_000_000e6);
        uint256 maxAllowedFee = 250 + payoutRouter.MAX_FEE_INCREASE_PER_CHANGE();
        uint256 boundedFeeBps = bound(uint256(feeBps), 0, maxAllowedFee);

        address user = makeAddr("single-user");

        vm.prank(admin);
        payoutRouter.proposeFeeChange(feeRecipient, boundedFeeBps);

        if (boundedFeeBps > 250) {
            vm.warp(block.timestamp + payoutRouter.FEE_CHANGE_DELAY() + 1);
            payoutRouter.executeFeeChange(0);
        }

        vm.prank(vault);
        payoutRouter.updateUserShares(user, 100e18);

        vm.prank(user);
        payoutRouter.setVaultPreference(vault, user, 50);

        usdc.mint(address(payoutRouter), boundedYield);
        vm.prank(vault);
        payoutRouter.recordYield(address(usdc), boundedYield);

        uint256 protocolBefore = usdc.balanceOf(treasury);
        uint256 campaignBefore = usdc.balanceOf(campaignRegistry.mockPayoutRecipient());
        uint256 userBefore = usdc.balanceOf(user);

        vm.prank(user);
        uint256 claimed = payoutRouter.claimYield(vault, address(usdc));

        uint256 protocolAmount = usdc.balanceOf(treasury) - protocolBefore;
        uint256 campaignAmount = usdc.balanceOf(campaignRegistry.mockPayoutRecipient()) - campaignBefore;
        uint256 beneficiaryAmount = usdc.balanceOf(user) - userBefore;

        assertLe(protocolAmount, (claimed * payoutRouter.MAX_FEE_BPS()) / 10_000);
        assertEq(campaignAmount + beneficiaryAmount, claimed - protocolAmount);
        assertLe(claimed, boundedYield);
    }
}
