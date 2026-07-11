// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

interface IGaugeHookReceiver {
    /// @notice Get the gauge for the share token
    function configuredGauges(
        address _shareToken
    ) external view returns (address);
}
