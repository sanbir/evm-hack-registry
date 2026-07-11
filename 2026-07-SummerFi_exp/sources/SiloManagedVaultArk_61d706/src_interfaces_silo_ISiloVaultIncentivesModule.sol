// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

interface ISiloVaultIncentivesModule {
    function getNotificationReceivers()
        external
        view
        returns (address[] memory);
}
