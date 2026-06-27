// SPDX-License-Identifier: MIT
pragma solidity ^0.8.4;

interface IGnosisXdaiBridge {
    /**
     * @notice Method bridges ERC20 XDAI from mainnet to native xDai on Gnosis
     */
    function relayTokens(address _receiver, uint256 _amount) external payable;
}

interface IGnosisOmniBridge {
    /**
     * @notice Method Bridges ERC20 tokens from mainnet to gnosis
     */
    function relayTokens(
        address token,
        address _receiver,
        uint256 _value
    ) external payable;
}

interface IGnosisWethOmniBridgeHelper {
    /**
     * @notice Method wraps native ETH on mainnet and bridges Weth to gnosis
     */
    function wrapAndRelayTokens(address _receiver) external payable;
}
