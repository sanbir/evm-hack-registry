// SPDX-License-Identifier: MIT

pragma solidity 0.8.19;

interface ITimelockTemp {
    function marginFeeBasisPoints() external view returns (uint256);

    function setAdmin(address _admin) external;

    function enableLeverage(address _vault) external;

    function disableLeverage(address _vault) external;

    function setIsLeverageEnabled(address _vault, bool _isLeverageEnabled)
        external;

    function signalSetGov(address _target, address _gov) external;

    function admin() external view returns (address);
}
