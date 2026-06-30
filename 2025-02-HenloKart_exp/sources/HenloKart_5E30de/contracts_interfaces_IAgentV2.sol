/// SPDX-License-Identifier: MIT 

pragma solidity ^0.8.0;

interface IAgentV2 {
    /**
     * Reset the agent's policy to its initial state. Can only be called by the owner of the agent.
     * @param game The address of the game to reset the agent's state for.
     * @param tokenId The token ID of the agent.
     * @param numStates The number of states in the game to reset.
     * @param numActions The number of actions in the game to reset.
     */
    function reset(address game, uint64 tokenId, uint64 numStates, uint64 numActions) external;

    /**
     * Setup the game environment for the agent with the game definition and initial state.
     * @param tokenId The token ID of the agent.
     * @param gameDefinition The definition of the game being played.
     */
    function setup(
      uint64 tokenId,
      bytes32[] calldata gameDefinition
    ) external;

    /**
     * Select an action based on the agent's policy.
     * @notice The action selected is based on the game being played (the msg.sender).
     * @param tokenId The token ID of the agent.
     * @param rngSeed A game-provided seed for to be optionally used by the agent.
     * @param _prevState The previous state of the game being played.
     * @param _prevAction The action(s) taken in the previous state.
     * @param _state The current state of the game being played.
     * @param _reward The observed reward, if any, for the previous action(s) taken.
     * @return action The action the agent suggests to take
     */
    function selectAction(
        uint64 tokenId,
        bytes32 rngSeed,
        bytes32[] calldata _prevState,
        bytes32[] calldata _prevAction,
        bytes32[] calldata _state,
        bytes32[] calldata _reward
    ) external returns (bytes32[] memory action);
}