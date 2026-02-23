// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ACLManager} from "../../src/governance/ACLManager.sol";
import {StrategyRegistry} from "../../src/registry/StrategyRegistry.sol";
import {CampaignRegistry} from "../../src/registry/CampaignRegistry.sol";
import {NGORegistry} from "../../src/donation/NGORegistry.sol";

library ForkHelperConfig {
    uint256 internal constant CAMPAIGN_SUBMISSION_DEPOSIT = 0.005 ether;
    uint256 internal constant DEFAULT_TARGET_STAKE_USDC = 100_000e6;
    uint256 internal constant DEFAULT_MIN_STAKE_USDC = 1_000e6;

    uint16 internal constant DEFAULT_CHECKPOINT_QUORUM_BPS = 2_000;
    uint64 internal constant DEFAULT_CHECKPOINT_WINDOW = 2 days;

    bytes32 internal constant LOCK_PROFILE_STANDARD = keccak256("fork.lock.standard");

    bytes32 internal constant NGO_MANAGER_ROLE = keccak256("NGO_MANAGER_ROLE");
    bytes32 internal constant DONATION_RECORDER_ROLE = keccak256("DONATION_RECORDER_ROLE");
    bytes32 internal constant GUARDIAN_ROLE = keccak256("GUARDIAN_ROLE");

    struct RegistrySuite {
        ACLManager acl;
        StrategyRegistry strategyRegistry;
        CampaignRegistry campaignRegistry;
        NGORegistry ngoRegistry;
    }

    function initAllRegistries(address admin) internal returns (RegistrySuite memory suite) {
        suite.acl = new ACLManager();
        suite.acl.initialize(admin, admin);

        suite.strategyRegistry = new StrategyRegistry();
        suite.strategyRegistry.initialize(address(suite.acl));

        suite.campaignRegistry = new CampaignRegistry();
        suite.campaignRegistry.initialize(address(suite.acl), address(suite.strategyRegistry));

        suite.ngoRegistry = new NGORegistry();
        suite.ngoRegistry.initialize(address(suite.acl));
    }

    function grantCoreProtocolRoles(ACLManager acl, address admin, address checkpointCouncil) internal {
        acl.grantRole(acl.protocolAdminRole(), admin);
        acl.grantRole(acl.strategyAdminRole(), admin);
        acl.grantRole(acl.campaignAdminRole(), admin);
        acl.grantRole(acl.campaignCuratorRole(), admin);
        if (checkpointCouncil != address(0)) {
            acl.grantRole(acl.checkpointCouncilRole(), checkpointCouncil);
        }
    }

    function grantNgoRegistryRoles(ACLManager acl, address admin, address donationRecorder) internal {
        acl.createRole(NGO_MANAGER_ROLE, admin);
        acl.grantRole(NGO_MANAGER_ROLE, admin);

        acl.createRole(GUARDIAN_ROLE, admin);
        acl.grantRole(GUARDIAN_ROLE, admin);

        acl.createRole(DONATION_RECORDER_ROLE, admin);
        if (donationRecorder != address(0)) {
            acl.grantRole(DONATION_RECORDER_ROLE, donationRecorder);
        }
    }

    function wireCampaignNgoRegistry(CampaignRegistry campaignRegistry, NGORegistry ngoRegistry) internal {
        campaignRegistry.setNGORegistry(address(ngoRegistry));
    }

    function addApprovedNgo(NGORegistry ngoRegistry, address ngo, string memory metadataCid, bytes32 kycHash) internal {
        ngoRegistry.addNGO(ngo, metadataCid, kycHash, msg.sender);
    }
}
