/// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

import {IGameV1} from '../../../interfaces/IGameV1.sol'; 

interface IHenloKartV1 is IGameV1 {
    /**
     * A commitment to race a specific hamster for a specific bet size.
     * @param player The player committing to bet
     * @param agent The agent used to race and train the hamster. If the agent set by the owner
                    is different at the time of the race, the commitment will be disqualified for
                    that race.
     * @param betToken The token used for the bet
     * @param tokenId The token ID of the hamster to be raced and trained
     * @param betSize The size of the bet on each race
     * @param creditsUsed The amount of the commitment paid for via credit, needed for cancellation
     * @param deadline The timestamp that the commitment must be executed before being cancelled
     * @param count The maximum number of races that can be run with this commitment
     * @param rngSeed The random number seed generated upon commitment, used within each race
     */
    struct RaceCommitment {
        address player;
        address agent;
        address betToken;
        uint256 tokenId;
        uint256 betSize;
        uint256 creditsUsed;
        uint64 deadline;
        uint64 count;
        uint64 rngSeed;
    }
    
    /** 
     * The current position of a hamster within an active game.
     * @param x The x-coordinate of the hamster
     * @param direction The direction the hamster is facing
     */
    struct HamsterPosition {
        uint8 x;
        uint8 direction;
    }
    
    event PlayerCommitted(RaceCommitment commitment, bytes32 commitmentHash);
    event CommitmentCancelled(bytes32 commitmentHash, uint256 creditsRefunded);
    event RaceFinished(
        uint256 winningTokenId,
        address winner,
        address executor,
        address betToken,
        uint256 betSize,
        uint256 raceId,
        uint256 steps,
        bytes32[] commitmentHashes,
        uint64[] racingOrder,
        uint8[] actionSequence,
        HamsterPosition[] positions
    );
    event RewardPaid(
        address winner,
        address betToken,
        uint256 creditSize,
        uint256 instantSize
    );
    
    event JackpotSet(address jackpot);
    event FeeReceiverSet(address feeReceiver);
    event FeePercentSet(uint256 feePercent);
    event RewardFeePercentSet(uint256 rewardFeePercent);
    event CommitmentLockPeriodSet(uint256 lockPeriod);
    event BetTokenToggled(address token, bool enabled);
    event HamsterAgentToggled(address agent, bool enabled);
    event BetSizeToggled(address token, uint256 betSize, bool enabled);
    event RacingToggled(bool enabled);
    error InvalidHamsterAgent(address agent);
    error IncompatibleAgents(address executingAgent, address commitmentAgent);
    error DuplicateCommitment(bytes32 commitmentHash);
    error DuplicatePet(uint256 tokenId);
    error InvalidTokenId(uint256 tokenId);
    error InvalidBetToken(address token);
    error InvalidBetSize(uint256 commitmentBetSize);
    error InvalidBetSizeForToken(address betToken, uint256 betSize);
    error InvalidCommitmentLength(uint256 length, uint256 expectedLength);
    error CommitmentOverused(bytes32 commitmentHash);
    error FeePercentTooHigh(uint256 maxFeePercent);
    error InvalidCommitmentLockPeriod(uint256 maxCommitmentLockPeriod);
    error CommitmentExpired(bytes32 commitmentHash);
    error InvalidCommitmentDeadline(uint256 commitmentLockPeriod);
    error InvalidCommitmentPlayer();
    error RacingNotEnabled();
    error InsufficientAllowance(uint256 betSize);
    error InsufficientBalance(uint256 betSize);
    error CommitmentLocked(uint256 lockedUntil);
    error CommitmentFromSameBlock(bytes32 commitmentHash);
    error GameFailed(uint256 steps);
    error AdminHasBeenRevoked();

    function directory() external view returns (address);
    function jackpot() external view returns (address);
    function raceId() external view returns (uint256);
    function countUsed(bytes32 commitmentHash) external view returns (uint256);

    /**
     * Gets the RaceCommitment struct stored for a specific commitment hash
     * @param commitmentHash The hash to retrieve on-chain
     @ @return rc The race commitment stored for the provided hash
     */
    function getCommitment(bytes32 commitmentHash) external view returns (RaceCommitment memory);

    /** 
     * Gets the definition of the observation space, action space, and recommended training parameters.
     * @return game The game definition:
            game[0]: Observation space: uint256(NUM_STATES)
            game[1]: Action space: uint256(NUM_ACTIONS)
            game[2]: Suggested Learning rate: uint256(LEARNING_RATE)
            game[3]: Suggested Discount factor: uint256(DISCOUNT_FACTOR)
     */
    function getDefinition() external view returns (bytes32[] memory game);

    /** 
     * Gets the reward of a hamster taking a specific action.
     * @param xPosition The new x-coordinate of the hamster
     * @param trackSize The size of the track being raced on
     * @return reward The reward of the hamster taking the action
     *       reward[0]: The reward for this action: uint256(REWARD)
     */
    function getReward(uint8 xPosition, uint256 trackSize) external view returns (bytes32[] memory reward);

    /**
     * Checks if the given commitment hash is valid to be competed against.
     * @param agent The agent type to be used by the executor of the race
     * @param betToken The token to be used for the bet
     * @param tokenId The token ID of the hamster to be raced and trained
     * @param betSize The size of the bet to be used
     * @param commitmentHash The hash of the commitment to check
     * @return valid True if the commitment is valid, false otherwise
     */
    function isValidCommitment(
        address agent,
        address betToken,
        uint256 tokenId,
        uint256 betSize,
        bytes32 commitmentHash
    ) external view returns (bool valid);

    /**
     * Checks if the given contract address has been whitelisted as a hamster agent type for this game.
     * @param agent The address of the contract to check
     * @return True if the contract is a valid hamster agent type, false otherwise
     */
    function isValidHamsterAgent(address agent) external view returns (bool);

    /** 
     * An admin function to update the fee receiver address.
     * @param _feeReceiver The new fee receiver address
     */
    function setFeeReceiver(address _feeReceiver) external;

    /** 
     * An admin function to update the fee percentage taken from each bet.
     * @notice The fee percentage is a value between 0 and 1000, where 1000 represents
     *         the maximum possible fee percentage of 10%.
     * @param _feePercent The new fee percentage
     */
    function setFeePercent(uint256 _feePercent) external;

    /** 
     * An admin function to update the percentage taken from each bet to go to the player reward fund.
     * @notice The reward fee percentage is a value between 0 and 1000, where 1000 represents
     *         the maximum possible reward fee percentage of 10%.
     * @param _rewardFeePercent The new reward fee percentage
     */
    function setRewardFeePercent(uint256 _rewardFeePercent) external;

    /** 
     * An admin function to update the commitment lock period.
     * @param _commitmentLockPeriod The new commitment lock period
     */
    function setCommitmentLockPeriod(uint256 _commitmentLockPeriod) external;

    /**
     * An admin function to enable/disable a specific agent type for racing.
     * @param agent The address of the agent type to whitelist
     * @param enabled Whether the agent is raceable or not
     */
    function toggleHamsterAgent(address agent, bool enabled) external;

    /** 
     * An admin function to enable/disable a new bet token.
     * @param _betToken The token to enable/disable for betting
     * @param enabled Whether the bet token is allowed or not
     */
    function toggleBetToken(address _betToken, bool enabled) external;

    /** 
     * An admin function to enable/disable a new bet size for a specific bet token.
     * @param _betToken The token to bet with
     * @param _betSize The size enabled/disabled
     * @param enabled Whether the bet size is allowed or not
     */
    function toggleBetSize(address _betToken, uint256 _betSize, bool enabled) external;

    /**
     * An admin function to enable racing to begin.
     * @param enabled Whether racing is allowed or not
     */
    function toggleRacing(bool enabled) external;
    
    /** 
     * Creates a RaceCommitment on-chain that can be used by any other player.
     * @notice The agent that will race and train the hamster is determined by the owner.
     *         Each hamster's chosen agent is set on the AgentDirectoryV1 contract.
     * @param agent The agent type used to race and train the hamster. The agent must be the agent set
                    by the owner at the time of the race, otherwise the commitment will be disqualified
                    for that race.
     * @param betToken The token used to bet on races
     * @param tokenId The token ID of the hamster to be raced and trained
     * @param betSize The size of the bet on each race
     * @param deadline The timestamp that the commitment must be executed before being cancelled
     * @param count The maximum number of races that can be run with this commitment
     * @return commitmentHash The commitment hash that was created
     */
    function commitToRace(
        address agent,
        address betToken,
        uint256 tokenId,
        uint256 betSize,
        uint64 deadline,
        uint64 count
    ) external payable returns (bytes32 commitmentHash);    
    
    /** 
     * Creates a RaceCommitment on-chain that can be used by any other player.
     * @notice The agent that will race and train the hamster is determined by the owner.
     *         Each hamster's chosen agent is set on the AgentDirectoryV1 contract.
     * @param player The player committing to bet
     * @param agent The agent type used to race and train the hamster. The agent must be the agent set
                    by the owner at the time of the race, otherwise the commitment will be disqualified
                    for that race.
     * @param betToken The token used to bet on races
     * @param tokenId The token ID of the hamster to be raced and trained
     * @param betSize The size of the bet on each race
     * @param deadline The timestamp that the commitment must be executed before being cancelled
     * @param count The maximum number of races that can be run with this commitment
     * @return commitmentHash The commitment hash that was created
     */
    function commitToRace(
        address player,
        address agent,
        address betToken,
        uint256 tokenId,
        uint256 betSize,
        uint64 deadline,
        uint64 count
    ) external payable returns (bytes32 commitmentHash);

    /**
     * Cancels an on-chain RaceCommitment that has not been executed
     * @param commitmentHash The commitment hash to cancel
     */
    function cancelCommitment(bytes32 commitmentHash) external;

    /** 
     * Executes a race between hamsters that have already committed to races on-chain.
     * @notice The agent that will race and train the hamster is determined by the owner.
     *         Each hamster's chosen agent is set on the AgentDirectoryV1 contract.
     * @param commitmentHashes The on-chain commitment hashes from other players
     * @return steps The number of steps the race took to fully execute
     */
    function executeRace(
        bytes32[] memory commitmentHashes
    ) external returns (uint256);
}