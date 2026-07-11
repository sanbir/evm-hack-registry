// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

/**
 * @notice Initialization parameters for the ConfigurationManager contract
 */
struct ConfigurationManagerParams {
    address raft;
    address tipJar;
    address treasury;
    address harborCommand;
    address fleetCommanderRewardsManagerFactory;
}
