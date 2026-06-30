/// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

interface IJackpotV1 {
    event JackpotPaid(
        address betToken,
        address[] winners,
        uint256[] creditSizes,
        uint256[] instantSizes
    );
    event PayoutCallerSet(address payoutCaller);
    event PotTokenSet(address potToken);
    event RolloverPercentSet(uint256 rolloverPercent);
    event CreditRatioSet(uint256 creditRatio);
    event RewardPeriodSet(uint256 rewardPeriod);
    event RewardCategorySizesSet(uint256[] rewardCategorySizes);
    event RandomRewardedPlayersSet(uint256 randomRewardedPlayers);
    event NeverWonRewardedPlayersSet(uint256 neverWonRewardedPlayers);
    event ActivePercentRewardedSet(uint256 activePercentRewarded);
    event RewardPercentsSet(uint256[] rewardPercents);
    event BetTierMultipliersSet(uint256[] betTierSizes, uint256[] betTierMultipliers);
    event GameToggled(address game, bool enabled);
    event RewardTokenToggled(address token, bool enabled);
    event FundCommitment(address player, address betToken, uint256 betSize, uint256 count);
    event RewardsStarted(uint256 startTime);
    event RewardsDeposited(address betToken, uint256 amount);
    event RewardsWithdrawn(address betToken, uint256 amount);

    error RolloverPercentTooHigh(uint256 maxRolloverPercent);
    error RatioTooHigh(uint256 maxRatio);
    error RewardCategorySizesInvalidSum(uint256 sum, uint256 expectedSum);
    error RewardPercentsSumTooHigh(uint256 sum);
    error InsufficientCreditBalance(address player, uint256 creditBalance);
    error RewardsAlreadyStarted();
    error RewardsNotYetStarted();
    error InvalidPayoutCaller(address caller, address expectedCaller);
    error RewardTimeNotReady(uint256 nextRewardTime);
    error GameNotEnabled(address game);
    error RewardTokenNotEnabled(address token);
    error WithdrawTooLarge(uint256 maxWithdraw);
    error AdminHasBeenRevoked();
    error LengthMismatch(uint256 betTierSizesLength, uint256 betTierMultipliersLength);

    function currentRound() external view returns (uint256);
    function lastRewardTimestamp(address betToken) external view returns (uint256);
    function conversionFactor(address betToken) external view returns (uint256);
    function rewardStartTime() external view returns (uint256);
    function rewardPeriod() external view returns (uint256);
    function rewardSize(address betToken, address rewardToken) external view returns (uint256);
    function gameCredits(address betToken, address player) external view returns (uint256);
    function creditsRefunded(bytes32 commitmentHash) external view returns (uint256);
    function gameEnabled(address game) external view returns (bool);
    function rewardTokenEnabled(address token) external view returns (bool);
    function rewardCategorySizes() external view returns (uint256[] memory);
    function rewardPercents() external view returns (uint256[] memory);
    function rolloverPercent() external view returns (uint256);
    function activePercentRewarded() external view returns (uint256);
    function randomRewardedPlayers() external view returns (uint256);
    function creditRatio() external view returns (uint256);
    function pastWinners(address winner) external view returns (bool);

    /** 
     * An admin function to update the payout caller address.
     * @param _payoutCaller The new payout caller address
     */
    function setPayoutCaller(address _payoutCaller) external;

    /** 
     * An admin function to update the pot payout token address.
     * @param _potToken The new pot payout token
     */
    function setPotToken(address _potToken) external;

    /** 
     * An admin function to update the rollover percentage taken from each bet to go to the player reward fund.
     * @notice The rollover percentage is a value between 0 and 1000, where 1000 represents
     *         the maximum possible rollover percentage of 10%.
     * @param _rolloverPercent The new rollover percentage
     */
    function setRolloverPercent(uint256 _rolloverPercent) external;

    /** 
     * An admin function to update the reward reward credit ratio.
     * @param _creditRatio The new reward reward credit ratio
     */
    function setCreditRatio(uint256 _creditRatio) external;

    /** 
     * An admin function to update the recurring period in which the reward is distributed.
     * @param _rewardPeriod The new reward reward period
     */
    function setRewardPeriod(uint256 _rewardPeriod) external;

    /** 
     * An admin function to update the percentage of rewards distributed to each category of winners.
     * @param _rewardCategorySizes The list of sizes (base of 10_000), must add up to 100%
     */
    function setRewardCategorySizes(uint256[] memory _rewardCategorySizes) external;

    /** 
     * An admin function to update the number of random players to reward each payout.
     * @param _randomRewardedPlayers The new number of random players to reward each payout
     */
    function setRandomRewardedPlayers(uint256 _randomRewardedPlayers) external;

    /** 
     * An admin function to update the number of never won players to reward each payout.
     * @param _neverWonRewardedPlayers The new number of never won players to reward each payout
     */
    function setNeverWonRewardedPlayers(uint256 _neverWonRewardedPlayers) external;

    /**
     * An admin function to update the percentage of active players to reward each payout.
     * @param _activePercentRewarded The new percentage of active players to reward each payout
     */
    function setActivePercentRewarded(uint256 _activePercentRewarded) external;

    /** 
     * An admin function to update the percent per top reward reward distribution.
     * @param _rewardPercents The new reward reward distribution percents
     */
    function setRewardPercents(uint256[] memory _rewardPercents) external;

    /**
     * An admin function to update the bet tier sizes and multipliers.
     * @param _betTierSizes The new bet tier sizes
     * @param _betTierMultipliers The new bet tier multipliers
     */
    function setBetTierMultipliers(uint256[] memory _betTierSizes, uint256[] memory _betTierMultipliers) external;

    /**
     * An admin function to enable a game for rewards.
     * @param _game The game to enable
     * @param enabled Whether the game is allowed or not
     */
    function toggleGame(address _game, bool enabled) external;
    
    /**
     * An admin function to enable a reward token.
     * @param _rewardToken The token to reward
     * @param enabled Whether the reward token is allowed or not
     */
    function toggleRewardToken(address _rewardToken, bool enabled) external;
    
    /**
     * An admin function to start distributing rewards. Cannot be undone.
     */
    function startRewards() external;

    /**
     * A function only callable by whitelisted games to fund a player's commitment with credits.
     * @param player The address of the player
     * @param betToken The token to player bet with
     * @param totalSize The total size of the player's bet for the commitment (betSize * count)
     * @return creditsUsed The number of credits used to fund the commitment
     */
    function fundCommitment(
        address player,
        address betToken,
        uint256 totalSize
    ) external returns (uint256 creditsUsed);

    /**
     * A function only callable by whitelisted games to refund a player's credits from a commitment.
     * @param player The address of the player
     * @param betToken The token to player bet with
     * @param totalSize The total size of the player's bet for the commitment (betSize * count)
     * @param initialCredits The total number of credits used to fund the commitment
     * @param commitmentHash The hash of the commitment being cancelled and refunded
     * @return _creditsRefunded The number of credits refunded to cancel the commitment
     */
    function refundCommitment(
        address player,
        address betToken,
        uint256 totalSize,
        uint256 initialCredits,
        bytes32 commitmentHash
    ) external returns (uint256 _creditsRefunded);

    /**
     * Adds credits to a player's account by transferring the bet token into credits
     * @param player The player address to credit
     * @param betToken The token to deposit
     * @param creditSize The amount of the token to deposit
     */
    function addCredits(address player, address betToken, uint256 creditSize) external payable;

    /**
     * A function only callable by whitelisted games to update player stats.
     * @param player The address of the player
     * @param betToken The token to player bet with
     * @param betSize The size of the player's bet
     */
    function updatePlayer(address player, address betToken, uint256 betSize) external;

    /**
     * Pay out the reward fund to active and random players from the current reward period.
     * @notice This function can be called by anyone to determine RNG and distribute rewards
     *         once the reward period has passed.
     * @notice It is encouraged to call this function ASAP if it is available.
     * @param betToken The token's reward to add to, and the token to deposit
     * @param swapCallee The contract to call to execute a swap from bet token to pot token
     * @param swapAllowanceTarget The contract to provide swap allowance for
     * @param swapData The data to execute the swap
     */
    function payoutRewards(
        address betToken,
        address swapCallee,
        address swapAllowanceTarget,
        bytes calldata swapData
    ) external;

    /**
     * Add tokens to the corresponding bet token reward fund. Only deposit if you know what you
     * are doing.
     * @notice Requires `msg.sender` to have given the contract approval to transfer
     *         `amount` of `betToken`.
     * @param betToken The token's reward to add to
     * @param rewardToken The token to deposit as a reward
     * @param amount The amount of `betToken` to deposit to the reward
     */
    function depositRewards(address betToken, address rewardToken, uint256 amount) external payable;

    /**
     * An admin function to withdraw tokens from the corresponding bet token reward fund.
     * @notice Intended to be used to withdraw capital for yield-bearing purposes.
               Amount than can be withdrawn is limited.
     * @param betToken The token's reward to withdraw from
     * @param rewardToken The token to withdraw
     * @param amount The amount of `betToken` to withdraw from the reward
     */
    function withdrawRewards(address betToken, address rewardToken, uint256 amount) external;
}