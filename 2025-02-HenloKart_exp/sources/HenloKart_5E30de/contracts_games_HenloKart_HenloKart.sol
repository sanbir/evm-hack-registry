/// SPDX-License-Identifier: MIT

pragma solidity ^0.8.24;

import {OwnableUpgradeable} from '@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol';
import {UUPSUpgradeable} from '@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol';
import {ReentrancyGuardUpgradeable} from '@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol';

import {HenloKartStorage} from './HenloKartStorage.sol';
import {IHenloKartV1} from './interfaces/IHenloKartV1.sol';
import {IOGsNFT} from '../../interfaces/IOGsNFT.sol';
import {IAgentV2} from '../../interfaces/IAgentV2.sol';
import {IAgentDirectoryV2} from '../../interfaces/IAgentDirectoryV2.sol';
import {IJackpotV1} from '../../interfaces/IJackpotV1.sol';
import {Arrays} from '../../libraries/Arrays.sol';
import {Conversion} from '../../libraries/Conversion.sol';
import {Math} from '../../libraries/Math.sol';
import {SimpleRNG} from '../../libraries/rng/SimpleRNG.sol';
import {Transfers} from '../../libraries/Transfers.sol';

contract HenloKart is IHenloKartV1, UUPSUpgradeable, OwnableUpgradeable, ReentrancyGuardUpgradeable {
  using Arrays for uint256[];
  using Conversion for int256;

  // Onchain Gaias: https://gaias.xyz
  IOGsNFT public constant NFT = IOGsNFT(0xA449b4f43D9A33FcdCF397b9cC7Aa909012709fD);

  uint256 private constant NUM_DIRECTIONS = 4; // →, ↑, ←, ↓
  uint256 private constant NUM_PLAYERS = 4;
  uint256 private constant NUM_ACTIONS = 3; // turn left, turn right, move forward
  uint256 private constant NO_BET_TRACK_SIZE = 10;
  uint256 private constant TRACK_SIZE = 18;
  uint256 private constant NO_BET_GAME_FAILURE_STEPS = 25;
  uint256 private constant GAME_FAILURE_STEPS = 60;
  uint256 private constant DEFAULT_DENOMINATOR = 10_000;
  uint256 private constant MAX_ARCHITECT_TOKEN_ID = 499;
  uint256 private constant MAX_FEE_PERCENT = 1000; // 10%

  receive() external payable {}

  function initialize(address _directory, address _jackpot, address agent, address _feeReceiver) public initializer {
    __Ownable_init(msg.sender);
    __ReentrancyGuard_init();
    __UUPSUpgradeable_init();

    HenloKartStorage.Store storage $ = HenloKartStorage.store();

    $.rewardFeePercent = 1000; // 10%
    $.feePercent = 1000; // 10%
    $.commitmentLockPeriod = 1 days;

    $.directory = _directory;
    $.jackpot = _jackpot;
    $.feeReceiver = _feeReceiver;

    /// @dev: enable ETH as bet token
    address betToken = address(0);
    $.betTokenEnabled[betToken] = true;
    $.betSizeEnabled[betToken][uint256(0)] = true;
    $.betSizeEnabled[betToken][0.001 ether] = true;
    $.betSizeEnabled[betToken][0.01 ether] = true;

    $.enabledHamsterAgents[agent] = true;
  }

  function _authorizeUpgrade(
    address
  ) internal override onlyOwner {}

  /// @inheritdoc IHenloKartV1
  function directory() external view returns (address) {
    HenloKartStorage.Store storage $ = HenloKartStorage.store();
    return $.directory;
  }

  /// @inheritdoc IHenloKartV1
  function jackpot() external view returns (address) {
    HenloKartStorage.Store storage $ = HenloKartStorage.store();
    return $.jackpot;
  }

  /// @inheritdoc IHenloKartV1
  function raceId() external view returns (uint256) {
    HenloKartStorage.Store storage $ = HenloKartStorage.store();
    return $.raceId;
  }

  /// @inheritdoc IHenloKartV1
  function countUsed(
    bytes32 commitmentHash
  ) external view returns (uint256) {
    HenloKartStorage.Store storage $ = HenloKartStorage.store();
    return $.countUsed[commitmentHash];
  }

  /// @inheritdoc IHenloKartV1
  function getCommitment(
    bytes32 commitmentHash
  ) external view returns (RaceCommitment memory) {
    HenloKartStorage.Store storage $ = HenloKartStorage.store();
    return $.raceCommitments[commitmentHash];
  }

  /// @inheritdoc IHenloKartV1
  function getDefinition() public pure returns (bytes32[] memory game) {
    game = new bytes32[](4);
    game[0] = bytes32(TRACK_SIZE * NUM_DIRECTIONS);
    game[1] = bytes32(NUM_ACTIONS);
    return game;
  }

  /// @inheritdoc IHenloKartV1
  function getReward(uint8 xPosition, uint256 trackSize) public pure returns (bytes32[] memory reward) {
    int256 newDistance = Math.difference(uint256(xPosition), TRACK_SIZE - 1);
    bool hasWon = hasCrossedFinishLine(xPosition, trackSize);

    reward = new bytes32[](1);

    if (hasWon) {
      // Player reached the center
      reward[0] = int256(100 * int256(DEFAULT_DENOMINATOR)).convertToBytes();
    } else {
      // Manhattan distance to the center
      reward[0] = int256(-newDistance * int256(DEFAULT_DENOMINATOR)).convertToBytes();
    }

    return reward;
  }

  /// @inheritdoc IHenloKartV1
  function isValidCommitment(
    address agent,
    address betToken,
    uint256 tokenId,
    uint256 betSize,
    bytes32 commitmentHash
  ) external view returns (bool valid) {
    HenloKartStorage.Store storage $ = HenloKartStorage.store();
    RaceCommitment memory rc = $.raceCommitments[commitmentHash];

    if (!isValidHamsterAgent(agent)) {
      revert InvalidHamsterAgent(agent);
    }

    if (betToken != rc.betToken) {
      revert InvalidBetToken(betToken);
    }

    if (betSize != rc.betSize) {
      revert InvalidBetSize(betSize);
    }

    if (rc.deadline != 0 && rc.deadline < block.timestamp) {
      revert CommitmentExpired(commitmentHash);
    }

    if (tokenId == rc.tokenId) {
      revert DuplicatePet(rc.tokenId);
    }

    if ($.countUsed[commitmentHash] + 1 > rc.count) {
      revert CommitmentOverused(commitmentHash);
    }

    return true;
  }

  /// @inheritdoc IHenloKartV1
  function isValidHamsterAgent(
    address agent
  ) public view returns (bool) {
    HenloKartStorage.Store storage $ = HenloKartStorage.store();
    return $.enabledHamsterAgents[agent];
  }

  /// @inheritdoc IHenloKartV1
  function setFeeReceiver(
    address _feeReceiver
  ) external onlyOwner {
    HenloKartStorage.Store storage $ = HenloKartStorage.store();
    $.feeReceiver = _feeReceiver;
    emit FeeReceiverSet(_feeReceiver);
  }

  /// @inheritdoc IHenloKartV1
  function setFeePercent(
    uint256 _feePercent
  ) external onlyOwner {
    if (_feePercent > MAX_FEE_PERCENT) revert FeePercentTooHigh(MAX_FEE_PERCENT);
    HenloKartStorage.Store storage $ = HenloKartStorage.store();
    $.feePercent = _feePercent;
    emit FeePercentSet(_feePercent);
  }

  /// @inheritdoc IHenloKartV1
  function setRewardFeePercent(
    uint256 _rewardFeePercent
  ) external onlyOwner {
    if (_rewardFeePercent > MAX_FEE_PERCENT) revert FeePercentTooHigh(MAX_FEE_PERCENT);
    HenloKartStorage.Store storage $ = HenloKartStorage.store();
    $.rewardFeePercent = _rewardFeePercent;
    emit RewardFeePercentSet(_rewardFeePercent);
  }

  /// @inheritdoc IHenloKartV1
  function setCommitmentLockPeriod(
    uint256 _commitmentLockPeriod
  ) external onlyOwner {
    if (_commitmentLockPeriod > 1 days) revert InvalidCommitmentLockPeriod(1 days);
    HenloKartStorage.Store storage $ = HenloKartStorage.store();
    $.commitmentLockPeriod = _commitmentLockPeriod;
    emit CommitmentLockPeriodSet(_commitmentLockPeriod);
  }

  /// @inheritdoc IHenloKartV1
  function toggleHamsterAgent(address agent, bool enabled) external onlyOwner {
    HenloKartStorage.Store storage $ = HenloKartStorage.store();
    $.enabledHamsterAgents[agent] = enabled;
    emit HamsterAgentToggled(agent, enabled);
  }

  /// @inheritdoc IHenloKartV1
  function toggleBetToken(address _betToken, bool enabled) external onlyOwner {
    HenloKartStorage.Store storage $ = HenloKartStorage.store();
    $.betTokenEnabled[_betToken] = enabled;
    emit BetTokenToggled(_betToken, enabled);
  }

  /// @inheritdoc IHenloKartV1
  function toggleBetSize(address _betToken, uint256 _betSize, bool enabled) external onlyOwner {
    HenloKartStorage.Store storage $ = HenloKartStorage.store();
    $.betSizeEnabled[_betToken][_betSize] = enabled;
    emit BetSizeToggled(_betToken, _betSize, enabled);
  }

  /// @inheritdoc IHenloKartV1
  function toggleRacing(
    bool enabled
  ) external onlyOwner {
    HenloKartStorage.Store storage $ = HenloKartStorage.store();
    $.isRacingEnabled = enabled;
    emit RacingToggled(enabled);
  }

  /// @inheritdoc IHenloKartV1
  function commitToRace(
    address agent,
    address betToken,
    uint256 tokenId,
    uint256 betSize,
    uint64 deadline,
    uint64 count
  ) external payable returns (bytes32 commitmentHash) {
    return commitToRace(msg.sender, agent, betToken, tokenId, betSize, deadline, count);
  }

  /// @inheritdoc IHenloKartV1
  function commitToRace(
    address player,
    address agent,
    address betToken,
    uint256 tokenId,
    uint256 betSize,
    uint64 deadline,
    uint64 count
  ) public payable nonReentrant returns (bytes32 commitmentHash) {
    HenloKartStorage.Store storage $ = HenloKartStorage.store();

    if (!$.isRacingEnabled) {
      revert RacingNotEnabled();
    }

    if (tokenId > MAX_ARCHITECT_TOKEN_ID) {
      revert InvalidTokenId(tokenId);
    }

    if (!$.betTokenEnabled[betToken]) {
      revert InvalidBetToken(betToken);
    }

    if (!$.betSizeEnabled[betToken][betSize]) {
      revert InvalidBetSizeForToken(betToken, betSize);
    }

    if (deadline != 0 && deadline < block.timestamp + $.commitmentLockPeriod) {
      revert InvalidCommitmentDeadline($.commitmentLockPeriod);
    }

    commitmentHash = keccak256(abi.encodePacked(player, agent, betToken, tokenId, betSize, deadline, count));

    if ($.raceCommitments[commitmentHash].player != address(0)) {
      revert DuplicateCommitment(commitmentHash);
    }

    uint256 seed = uint256(
      keccak256(
        abi.encodePacked(
          block.prevrandao, block.number, block.timestamp, count, deadline, betSize, betToken, tokenId, agent, player
        )
      )
    );
    uint256[] memory rng = SimpleRNG.getRNG(seed, 1, 256);
    uint64 rngSeed = uint64(uint256(keccak256(abi.encode(rng[0]))));

    uint256 creditsUsed;
    if (betSize != 0) {
      uint256 deposit = betSize * uint256(count);
      creditsUsed = IJackpotV1($.jackpot).fundCommitment(player, betToken, deposit);
      uint256 valueOwed = deposit - creditsUsed;

      Transfers.transferToken(betToken, msg.sender, address(this), valueOwed);

      if (betToken == address(0)) {
        /// @dev: refund unnecessary ETH sent
        if (msg.value > valueOwed) {
          Transfers.transferToken(betToken, address(this), msg.sender, msg.value - valueOwed);
        }
      }
    }

    RaceCommitment memory rc =
      RaceCommitment(player, address(agent), address(betToken), tokenId, betSize, creditsUsed, deadline, count, rngSeed);

    $.raceCommitments[commitmentHash] = rc;
    $.commitmentLockStart[commitmentHash] = block.timestamp;

    emit PlayerCommitted(rc, commitmentHash);
  }

  /// @inheritdoc IHenloKartV1
  function cancelCommitment(
    bytes32 commitmentHash
  ) external nonReentrant {
    HenloKartStorage.Store storage $ = HenloKartStorage.store();
    RaceCommitment memory rc = $.raceCommitments[commitmentHash];
    if (rc.player != msg.sender) {
      revert InvalidCommitmentPlayer();
    }

    uint256 lockedUntil = $.commitmentLockStart[commitmentHash] + $.commitmentLockPeriod;
    if (lockedUntil < block.timestamp) {
      revert CommitmentLocked(lockedUntil);
    }

    uint256 unusedCount = uint256(rc.count - $.countUsed[commitmentHash]);
    if (unusedCount == 0) {
      revert CommitmentOverused(commitmentHash);
    }

    $.countUsed[commitmentHash] = rc.count;

    uint256 creditsRefunded;
    if (rc.betSize != 0) {
      uint256 deposit = rc.betSize * unusedCount;
      creditsRefunded =
        IJackpotV1($.jackpot).refundCommitment(rc.player, rc.betToken, deposit, rc.creditsUsed, commitmentHash);
      uint256 betTokenOwed = deposit - creditsRefunded;

      if (betTokenOwed > 0) {
        Transfers.transferToken(rc.betToken, address(this), rc.player, betTokenOwed);
      }

      if (creditsRefunded > 0) {
        Transfers.transferToken(rc.betToken, address(this), address($.jackpot), creditsRefunded);
      }
    }

    emit CommitmentCancelled(commitmentHash, creditsRefunded);
  }

  /// @inheritdoc IHenloKartV1
  function executeRace(
    bytes32[] memory commitmentHashes
  ) external nonReentrant returns (uint256) {
    HenloKartStorage.Store storage $ = HenloKartStorage.store();

    if (!$.isRacingEnabled) {
      revert RacingNotEnabled();
    }

    if (commitmentHashes.length != NUM_PLAYERS) {
      revert InvalidCommitmentLength(commitmentHashes.length, NUM_PLAYERS);
    }

    RaceCommitment[] memory commitments = new RaceCommitment[](NUM_PLAYERS);
    for (uint256 i = 0; i < NUM_PLAYERS; i++) {
      commitments[i] = $.raceCommitments[commitmentHashes[i]];
    }

    uint256 _raceId = $.raceId++;

    for (uint256 i = 0; i < NUM_PLAYERS; i++) {
      if ($.commitmentLockStart[commitmentHashes[i]] == block.timestamp) {
        revert CommitmentFromSameBlock(commitmentHashes[i]);
      }

      address ownerAgent = IAgentDirectoryV2($.directory).getAgent(commitments[i].tokenId, address(this));
      if (commitments[i].agent != ownerAgent || !isValidHamsterAgent(commitments[i].agent)) {
        revert InvalidHamsterAgent(commitments[i].agent);
      }

      uint256 commitmentCount = $.countUsed[commitmentHashes[i]] + 1;
      if (commitmentCount > commitments[i].count) {
        revert CommitmentOverused(commitmentHashes[i]);
      }

      if (commitments[i].deadline != 0 && commitments[i].deadline < block.timestamp) {
        revert CommitmentExpired(commitmentHashes[i]);
      }

      for (uint256 j = i + 1; j < NUM_PLAYERS; j++) {
        if (commitments[i].tokenId == commitments[j].tokenId) {
          revert DuplicatePet(commitments[i].tokenId);
        }
      }

      if (i != 0) {
        if (commitments[i].betSize != commitments[0].betSize) {
          revert InvalidBetSize(commitments[i].betSize);
        }

        if (commitments[i].betToken != commitments[0].betToken) {
          revert InvalidBetToken(commitments[i].betToken);
        }
      }

      $.countUsed[commitmentHashes[i]] = commitmentCount;
      IJackpotV1($.jackpot).updatePlayer(commitments[i].player, commitments[i].betToken, commitments[i].betSize);
    }

    uint256 seed =
      uint256(keccak256(abi.encodePacked(_raceId, commitmentHashes, block.timestamp, block.number, block.prevrandao)));

    uint64[] memory tokenIds;
    uint64[] memory rngSeeds;
    address[] memory players;
    address[] memory agents;
    (tokenIds, rngSeeds, players, agents) = randomizeOrder(commitments, seed);

    (uint256 steps, uint256 winningTokenId, uint8[] memory actionSequence, HamsterPosition[] memory positions) =
      race(tokenIds, rngSeeds, agents, seed, commitments[0].betSize == 0);

    address winner;
    for (uint256 i = 0; i < NUM_PLAYERS; i++) {
      if (commitments[i].tokenId == winningTokenId) {
        winner = commitments[i].player;
        break;
      }
    }

    {
      uint256 totalBetSize = commitments[0].betSize * NUM_PLAYERS;
      uint256 fee = totalBetSize * $.feePercent / DEFAULT_DENOMINATOR;
      uint256 rewardFee = totalBetSize * $.rewardFeePercent / DEFAULT_DENOMINATOR;

      if (commitments[0].betSize != 0) {
        if (commitments[0].betToken == address(0)) {
          IJackpotV1($.jackpot).depositRewards{value: rewardFee}(
            commitments[0].betToken, commitments[0].betToken, rewardFee
          );
        } else {
          IJackpotV1($.jackpot).depositRewards(commitments[0].betToken, commitments[0].betToken, rewardFee);
        }

        Transfers.transferToken(commitments[0].betToken, address(this), $.feeReceiver, fee);
        Transfers.transferToken(commitments[0].betToken, address(this), winner, totalBetSize - fee - rewardFee);
      }
    }

    emit RaceFinished(
      winningTokenId,
      winner,
      msg.sender,
      commitments[0].betToken,
      commitments[0].betSize,
      _raceId,
      steps,
      commitmentHashes,
      tokenIds,
      actionSequence,
      positions
    );

    return steps;
  }

  function race(
    uint64[] memory tokenIds,
    uint64[] memory rngSeeds,
    address[] memory agents,
    uint256 seed,
    bool freeRace
  )
    private
    returns (uint256 steps, uint256 winningTokenId, uint8[] memory actionSequence, HamsterPosition[] memory positions)
  {
    bytes32[] memory definition = getDefinition();
    uint256 trackSize = freeRace ? NO_BET_TRACK_SIZE : TRACK_SIZE;
    uint256 failureSteps = freeRace ? NO_BET_GAME_FAILURE_STEPS : GAME_FAILURE_STEPS;

    bytes32[][] memory prevState = new bytes32[][](NUM_PLAYERS);
    bytes32[][] memory prevAction = new bytes32[][](NUM_PLAYERS);

    positions = new HamsterPosition[](NUM_PLAYERS);
    actionSequence = new uint8[](NUM_PLAYERS * failureSteps);

    bool hasCrashed;
    bool hasWon;

    for (uint256 i = 0; i < NUM_PLAYERS; i++) {
      positions[i] = HamsterPosition(0, 0);
      prevState[i] = new bytes32[](1);
      prevAction[i] = new bytes32[](1);
      IAgentV2(agents[i]).setup(tokenIds[i], definition);
    }

    for (steps = 0; steps < failureSteps;) {
      for (uint256 i = 0; i < NUM_PLAYERS;) {
        bytes32[] memory state;
        bytes32[] memory action;
        {
          bytes32[] memory reward = getReward(positions[i].x, trackSize);
          state = toRaceState(positions[i]);
          action = IAgentV2(agents[i]).selectAction(
            tokenIds[i], bytes32(uint256(rngSeeds[i]++)), prevState[i], prevAction[i], state, reward
          );
        }

        (positions[i], hasCrashed, hasWon) =
          makeMove(positions[i], uint256(action[0]), seed + steps * failureSteps + i, trackSize);

        prevState[i][0] = state[0];
        prevAction[i][0] = action[0];

        {
          uint8 realizedAction = hasCrashed ? uint8(3) : uint8(uint256(action[0]));
          uint256 seq = steps * NUM_PLAYERS + i;
          actionSequence[seq] = realizedAction;
        }

        if (hasWon) return (steps, uint64(tokenIds[i]), actionSequence, positions);
        unchecked {
          i++;
        }
      }

      unchecked {
        steps++;
      }
    }

    /// @dev: if no player has won within failureSteps, we find the currently winning player
    ///       to prevent users from spending too much on gas.
    return (steps, findWinner(seed, tokenIds, positions), actionSequence, positions);
  }

  function findWinner(
    uint256 seed,
    uint64[] memory tokenIds,
    HamsterPosition[] memory _positions
  ) private pure returns (uint256 winningTokenId) {
    uint64[] memory winningTokenIds = new uint64[](NUM_PLAYERS);
    uint8 winningIndex;
    uint8 winningPositionX;

    for (uint256 i = 0; i < NUM_PLAYERS;) {
      if (_positions[i].x > winningPositionX) {
        winningPositionX = _positions[i].x;
        winningIndex = 0;
      }

      if (_positions[i].x == winningPositionX) {
        winningTokenIds[winningIndex++] = tokenIds[i];
      }

      unchecked {
        i++;
      }
    }

    uint256 tieSplit = seed % winningIndex;
    return winningTokenIds[tieSplit];
  }

  function toRaceState(
    HamsterPosition memory position
  ) private pure returns (bytes32[] memory state) {
    state = new bytes32[](1);
    state[0] = bytes32(position.x * NUM_DIRECTIONS + position.direction);
    return state;
  }

  function makeMove(
    HamsterPosition memory position,
    uint256 action,
    uint256 seed,
    uint256 trackSize
  ) private pure returns (HamsterPosition memory, bool hasCrashed, bool hasWon) {
    uint256[] memory rng = SimpleRNG.getRNG(seed, 1, 30);

    if (rng[0] == 1) {
      // bad luck, you crashed
      return (position, true, false);
    }

    if (action == 0) {
      position.direction = uint8((position.direction + 1) % NUM_DIRECTIONS);
    } else if (action == 1) {
      if (position.direction == 0) {
        position.direction = uint8(3);
      } else {
        position.direction = uint8((position.direction - 1) % NUM_DIRECTIONS);
      }
    } else if (action == 2) {
      if (position.direction == 0) {
        position.x = uint8(position.x + 1);
      } else if (position.direction == 2 && position.x > 0) {
        position.x = uint8(position.x - 1);
      } else {
        hasCrashed = true;
      }
    }

    return (position, hasCrashed, hasCrossedFinishLine(position.x, trackSize));
  }

  function hasCrossedFinishLine(uint8 xPosition, uint256 trackSize) private pure returns (bool) {
    return uint256(xPosition) == trackSize - 1;
  }

  function randomizeOrder(
    RaceCommitment[] memory commitments,
    uint256 seed
  )
    private
    pure
    returns (uint64[] memory order, uint64[] memory rngSeeds, address[] memory players, address[] memory agents)
  {
    uint256[] memory rng = SimpleRNG.getRNG(seed, Math.factorial(NUM_PLAYERS), 2);

    order = new uint64[](NUM_PLAYERS);
    rngSeeds = new uint64[](NUM_PLAYERS);
    players = new address[](NUM_PLAYERS);
    agents = new address[](NUM_PLAYERS);
    for (uint256 i = 0; i < NUM_PLAYERS; i++) {
      order[i] = uint64(commitments[i].tokenId);
      players[i] = commitments[i].player;
      agents[i] = commitments[i].agent;

      // @dev: intentionally allow overflow
      unchecked {
        rngSeeds[i] = uint64(seed + commitments[i].rngSeed + order[i] + uint256(uint160(players[i])));
      }
    }

    for (uint256 i = 0; i < NUM_PLAYERS; i++) {
      for (uint256 j = i + 1; j < NUM_PLAYERS; j++) {
        if (rng[i * NUM_PLAYERS + j - 1] == 0) {
          (order[i], order[j]) = (order[j], order[i]);
          (players[i], players[j]) = (players[j], players[i]);
          (agents[i], agents[j]) = (agents[j], agents[i]);
        }
      }
    }
  }
}
