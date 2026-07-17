// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.17;

interface IERC20TokenRegistry {
    event RegistryStateChanged(bool isEnabled);
    event GasTokenAdded(address erc20Token);
    event GasTokenRemoved(address erc20Token);
    event TokenLimit(address erc20Token, uint256 tokenLimit);

    function changeState(bool _enabled) external;

    function isGasToken(address token) external view returns (bool);

    function changeGasTokens(
        address[] memory _gasTokens,
        bool[] memory values
    ) external;

    function enabled() external view returns (bool);

    function tokenLimits(address) external returns (uint256);

    function setTokenLimits(
        address[] memory _tokens,
        uint256[] memory _tokenLimits
    ) external;

    function getTokenLimit(address _token) external view returns (uint256);
}
