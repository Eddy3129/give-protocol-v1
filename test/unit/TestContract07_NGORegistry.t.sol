// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {NGORegistry} from "../../src/donation/NGORegistry.sol";
import {ACLManager} from "../../src/governance/ACLManager.sol";

contract TestContract07_NGORegistry is Test {
    NGORegistry public ngoRegistry;
    ACLManager public aclManager;

    address public admin;
    address public upgrader;
    address public ngoManager;
    address public donationRecorder;
    address public guardian;
    address public protocolAdmin;
    address public ngo1;
    address public ngo2;

    function setUp() public {
        admin = makeAddr("admin");
        upgrader = makeAddr("upgrader");
        ngoManager = makeAddr("ngoManager");
        donationRecorder = makeAddr("donationRecorder");
        guardian = makeAddr("guardian");
        protocolAdmin = makeAddr("protocolAdmin");
        ngo1 = makeAddr("ngo1");
        ngo2 = makeAddr("ngo2");

        aclManager = new ACLManager();
        aclManager.initialize(admin, upgrader);

        ngoRegistry = new NGORegistry();
        ngoRegistry.initialize(address(aclManager));

        vm.startPrank(admin);
        aclManager.createRole(ngoRegistry.NGO_MANAGER_ROLE(), admin);
        aclManager.createRole(ngoRegistry.DONATION_RECORDER_ROLE(), admin);
        aclManager.createRole(ngoRegistry.GUARDIAN_ROLE(), admin);

        aclManager.grantRole(ngoRegistry.NGO_MANAGER_ROLE(), ngoManager);
        aclManager.grantRole(ngoRegistry.DONATION_RECORDER_ROLE(), donationRecorder);
        aclManager.grantRole(ngoRegistry.GUARDIAN_ROLE(), guardian);
        aclManager.grantRole(aclManager.protocolAdminRole(), protocolAdmin);
        vm.stopPrank();
    }

    function test_Contract07_Case01_addNGO_setsCurrentAndMetadata() public {
        bytes32 kycHash = keccak256("kyc-ngo1");
        address attestor = makeAddr("attestor");

        vm.prank(ngoManager);
        ngoRegistry.addNGO(ngo1, "ipfs://ngo-1", kycHash, attestor);

        assertEq(ngoRegistry.currentNGO(), ngo1);
        assertTrue(ngoRegistry.isApproved(ngo1));

        (
            string memory metadataCid,
            bytes32 storedKycHash,
            address storedAttestor,,,
            uint256 version,
            uint256 totalReceived,
            bool isActive
        ) = ngoRegistry.ngoInfo(ngo1);

        assertEq(metadataCid, "ipfs://ngo-1");
        assertEq(storedKycHash, kycHash);
        assertEq(storedAttestor, attestor);
        assertEq(version, 1);
        assertEq(totalReceived, 0);
        assertTrue(isActive);
    }

    function test_Contract07_Case02_updateNGO_incrementsVersionAndUpdatesKYC() public {
        vm.startPrank(ngoManager);
        ngoRegistry.addNGO(ngo1, "ipfs://ngo-1", keccak256("kyc-v1"), makeAddr("attestor"));
        ngoRegistry.updateNGO(ngo1, "ipfs://ngo-1-v2", keccak256("kyc-v2"));
        vm.stopPrank();

        (string memory metadataCid, bytes32 kycHash,,,, uint256 version,,) = ngoRegistry.ngoInfo(ngo1);
        assertEq(metadataCid, "ipfs://ngo-1-v2");
        assertEq(kycHash, keccak256("kyc-v2"));
        assertEq(version, 2);
    }

    function test_Contract07_Case03_recordDonation_tracksCumulativeAmount() public {
        vm.prank(ngoManager);
        ngoRegistry.addNGO(ngo1, "ipfs://ngo-1", keccak256("kyc-ngo1"), makeAddr("attestor"));

        vm.startPrank(donationRecorder);
        ngoRegistry.recordDonation(ngo1, 10e6);
        ngoRegistry.recordDonation(ngo1, 25e6);
        vm.stopPrank();

        (,,,,,, uint256 totalReceived,) = ngoRegistry.ngoInfo(ngo1);
        assertEq(totalReceived, 35e6);
    }

    function test_Contract07_Case04_timelockedCurrentNGOChange_executesAfterDelay() public {
        vm.startPrank(ngoManager);
        ngoRegistry.addNGO(ngo1, "ipfs://ngo-1", keccak256("kyc-ngo1"), makeAddr("attestor1"));
        ngoRegistry.addNGO(ngo2, "ipfs://ngo-2", keccak256("kyc-ngo2"), makeAddr("attestor2"));
        ngoRegistry.proposeCurrentNGO(ngo2);
        vm.stopPrank();

        assertEq(ngoRegistry.pendingCurrentNGO(), ngo2);

        vm.expectRevert(NGORegistry.TimelockNotReady.selector);
        ngoRegistry.executeCurrentNGOChange();

        vm.warp(block.timestamp + ngoRegistry.TIMELOCK_DELAY());
        ngoRegistry.executeCurrentNGOChange();

        assertEq(ngoRegistry.currentNGO(), ngo2);
        assertEq(ngoRegistry.pendingCurrentNGO(), address(0));
        assertEq(ngoRegistry.currentNGOChangeETA(), 0);
    }

    function test_Contract07_Case05_emergencySetCurrentNGO_clearsPending() public {
        vm.startPrank(ngoManager);
        ngoRegistry.addNGO(ngo1, "ipfs://ngo-1", keccak256("kyc-ngo1"), makeAddr("attestor1"));
        ngoRegistry.addNGO(ngo2, "ipfs://ngo-2", keccak256("kyc-ngo2"), makeAddr("attestor2"));
        ngoRegistry.proposeCurrentNGO(ngo2);
        vm.stopPrank();

        vm.prank(protocolAdmin);
        ngoRegistry.emergencySetCurrentNGO(ngo1);

        assertEq(ngoRegistry.currentNGO(), ngo1);
        assertEq(ngoRegistry.pendingCurrentNGO(), address(0));
        assertEq(ngoRegistry.currentNGOChangeETA(), 0);
    }

    function test_Contract07_Case06_removeNGO_reassignsCurrent() public {
        vm.startPrank(ngoManager);
        ngoRegistry.addNGO(ngo1, "ipfs://ngo-1", keccak256("kyc-ngo1"), makeAddr("attestor1"));
        ngoRegistry.addNGO(ngo2, "ipfs://ngo-2", keccak256("kyc-ngo2"), makeAddr("attestor2"));
        vm.stopPrank();

        vm.prank(ngoManager);
        ngoRegistry.removeNGO(ngo1);

        assertFalse(ngoRegistry.isApproved(ngo1));
        assertEq(ngoRegistry.currentNGO(), ngo2);
    }

    function test_Contract07_Case07_pause_blocksAdd_andUnpauseRestores() public {
        vm.prank(guardian);
        ngoRegistry.pause();

        vm.prank(ngoManager);
        vm.expectRevert();
        ngoRegistry.addNGO(ngo1, "ipfs://ngo-1", keccak256("kyc-ngo1"), makeAddr("attestor"));

        vm.prank(guardian);
        ngoRegistry.unpause();

        vm.prank(ngoManager);
        ngoRegistry.addNGO(ngo1, "ipfs://ngo-1", keccak256("kyc-ngo1"), makeAddr("attestor"));
        assertTrue(ngoRegistry.isApproved(ngo1));
    }

    function test_Contract07_Case08_onlyRecorderCanRecordDonation() public {
        vm.prank(ngoManager);
        ngoRegistry.addNGO(ngo1, "ipfs://ngo-1", keccak256("kyc-ngo1"), makeAddr("attestor"));

        vm.prank(makeAddr("unauthorized"));
        vm.expectRevert();
        ngoRegistry.recordDonation(ngo1, 1e6);
    }

    function test_Contract07_Case09_executeCurrentNGOChange_noPendingReverts() public {
        vm.expectRevert(NGORegistry.NoTimelockPending.selector);
        ngoRegistry.executeCurrentNGOChange();
    }

    function test_Contract07_Case10_proposeCurrentNGO_invalidNGOReverts() public {
        vm.prank(ngoManager);
        vm.expectRevert(NGORegistry.NGONotApproved.selector);
        ngoRegistry.proposeCurrentNGO(makeAddr("notApprovedNGO"));
    }

    function test_Contract07_Case11_emergencySetCurrentNGO_invalidNGOReverts() public {
        vm.prank(protocolAdmin);
        vm.expectRevert(NGORegistry.NGONotApproved.selector);
        ngoRegistry.emergencySetCurrentNGO(makeAddr("notApprovedNGO"));
    }

    function test_Contract07_Case12_unauthorizedPauseUnpauseReverts() public {
        vm.prank(makeAddr("unauthorized"));
        vm.expectRevert();
        ngoRegistry.pause();

        vm.prank(makeAddr("unauthorized"));
        vm.expectRevert();
        ngoRegistry.unpause();
    }

    function test_Contract07_Case13_unauthorizedRemoveNGOReverts() public {
        vm.prank(ngoManager);
        ngoRegistry.addNGO(ngo1, "ipfs://ngo-1", keccak256("kyc-ngo1"), makeAddr("attestor"));

        vm.prank(makeAddr("unauthorized"));
        vm.expectRevert();
        ngoRegistry.removeNGO(ngo1);
    }

    function test_Contract07_Case14_unauthorizedUpdateNGOReverts() public {
        vm.prank(ngoManager);
        ngoRegistry.addNGO(ngo1, "ipfs://ngo-1", keccak256("kyc-ngo1"), makeAddr("attestor"));

        vm.prank(makeAddr("unauthorized"));
        vm.expectRevert();
        ngoRegistry.updateNGO(ngo1, "ipfs://new-cid", keccak256("kyc-v2"));
    }

    function test_Contract07_Case15_ngoWalletCanManageMultipleDelegates() public {
        address delegate1 = makeAddr("delegate1");
        address delegate2 = makeAddr("delegate2");

        vm.prank(ngoManager);
        ngoRegistry.addNGO(ngo1, "ipfs://ngo-1", keccak256("kyc-ngo1"), makeAddr("attestor"));

        vm.prank(ngo1);
        ngoRegistry.setCampaignSubmitter(delegate1, true);
        vm.prank(ngo1);
        ngoRegistry.setCampaignSubmitter(delegate2, true);

        assertTrue(ngoRegistry.isCampaignSubmitter(ngo1, delegate1));
        assertTrue(ngoRegistry.isCampaignSubmitter(ngo1, delegate2));
        assertTrue(ngoRegistry.canSubmitCampaignFor(ngo1, ngo1));
        assertTrue(ngoRegistry.canSubmitCampaignFor(ngo1, delegate1));
        assertTrue(ngoRegistry.canSubmitCampaignFor(ngo1, delegate2));

        vm.prank(ngo1);
        ngoRegistry.setCampaignSubmitter(delegate1, false);
        assertFalse(ngoRegistry.isCampaignSubmitter(ngo1, delegate1));
        assertFalse(ngoRegistry.canSubmitCampaignFor(ngo1, delegate1));
    }

    function test_Contract07_Case16_ngoManagerDelegateChangeUsesTimelock() public {
        address delegate = makeAddr("delegate");

        vm.prank(ngoManager);
        ngoRegistry.addNGO(ngo1, "ipfs://ngo-1", keccak256("kyc-ngo1"), makeAddr("attestor"));

        vm.prank(ngoManager);
        ngoRegistry.proposeCampaignSubmitterChange(ngo1, delegate, true);

        (bool hasPending, bool allowed, uint256 eta) = ngoRegistry.pendingCampaignSubmitterChange(ngo1, delegate);
        assertTrue(hasPending);
        assertTrue(allowed);
        assertGt(eta, block.timestamp);

        vm.expectRevert(NGORegistry.TimelockNotReady.selector);
        ngoRegistry.executeCampaignSubmitterChange(ngo1, delegate);

        vm.warp(block.timestamp + ngoRegistry.TIMELOCK_DELAY() + 1);
        ngoRegistry.executeCampaignSubmitterChange(ngo1, delegate);

        assertTrue(ngoRegistry.isCampaignSubmitter(ngo1, delegate));
        assertTrue(ngoRegistry.canSubmitCampaignFor(ngo1, delegate));
    }

    function test_Contract07_Case17_nonNgoWalletCannotSetDelegate() public {
        address delegate = makeAddr("delegate");
        address notNgo = makeAddr("notNgo");

        vm.prank(ngoManager);
        ngoRegistry.addNGO(ngo1, "ipfs://ngo-1", keccak256("kyc-ngo1"), makeAddr("attestor"));

        vm.prank(notNgo);
        vm.expectRevert(abi.encodeWithSelector(NGORegistry.NGONotApprovedForDelegate.selector, notNgo));
        ngoRegistry.setCampaignSubmitter(delegate, true);
    }
}
