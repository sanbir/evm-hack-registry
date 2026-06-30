/// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

interface IGameV1 {
    /**
     * Gets the game definition as defined by the game creator.
     * @notice The definition of the game can be used for various purposes, such as
     *         verifying the game's integrity, providing information such as suggested
     *         training parameters to agents, defining the game's action space, observation
     *         space, reward structure, etc.
     * @return game The game definition.
     */
    function getDefinition() external view returns (bytes32[] memory game);
}