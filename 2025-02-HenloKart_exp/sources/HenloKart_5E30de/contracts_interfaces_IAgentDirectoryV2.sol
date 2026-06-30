/// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0; 

interface IAgentDirectoryV2 {
    event UpdateAgent(uint256 tokenId, address game, address agent);

    /**
     * Gets the default agent set to play a specific game if no agent is set by the owner.
     * @param game The game to be played
     * @return agent The default agent that will play the game
     */
    function defaultAgent(address game) external view returns (address);

    /**
     * Gets the agent set by the owner to play a specific game.
     * @param tokenId The token ID of the on-chain gaia
     * @param game The game to be played
     * @return agent The agent that will play the game
     */
    function getAgent(uint256 tokenId, address game) external view returns (address agent);

    /**
     * Sets the agent to play a specific game. Can only be called by the owner of the on-chain gaia.
     * @param tokenId The token ID of the on-chain gaia
     * @param game The game to be played
     * @param agent The agent that will play the game
     */
    function setAgent(uint256 tokenId, address game, address agent) external;

    /**
     * Admin function to set the default agent to play a specific game.
     * @param game The game to be played
     * @param agent The default agent that will play the game
     */
    function setDefaultAgent(address game, address agent) external;
}