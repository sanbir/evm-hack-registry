// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*  KittenSwap ExternalBribe.earned — the loop stops before the last checkpoint
    (Pashov Audit Group, H-03, 7 May 2025, finding 58014).
    SYNTHETIC, cheatcode-free. One transaction, no warp inside run().
    The report's week-spaced deposit, withdraw, and redeposit are the two
    checkpoints below. Their timestamps are the previous epoch and the start
    of the current epoch, both derived from the single block.timestamp.
    At that state the gist logs earned = 0. The epoch that already closed
    still owes 100 RWD. The fixed loop includes _endIndex and pays the 100.
    The report's console.log lines are not part of the calculation and are
    omitted so this file stays free of forge-std. */

contract Token {
    string public constant name = "Reward";
    string public constant symbol = "RWD";
    uint8 public constant decimals = 18;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply += amount;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        require(balanceOf[msg.sender] >= amount, "bal");
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

struct Checkpoint {
    uint256 timestamp;
    uint256 balanceOf;
}

struct SupplyCheckpoint {
    uint256 timestamp;
    uint256 supply;
}

struct RewardCheckpoint {
    uint256 timestamp;
    uint256 balance;
}

struct PrevData {
    uint256 _prevSupply;
    uint256 _prevTs;
    uint256 _prevBal;
}

contract BribeLedger {
    uint256 public constant DURATION = 7 days;

    mapping(uint256 => mapping(uint256 => Checkpoint)) public checkpoints;
    mapping(uint256 => uint256) public numCheckpoints;
    mapping(uint256 => SupplyCheckpoint) public supplyCheckpoints;
    uint256 public supplyNum;
    mapping(address => mapping(uint256 => uint256)) public tokenRewardsPerEpoch;
    mapping(address => mapping(uint256 => uint256)) public lastEarn;

    function bribeStart(uint256 ts) public pure returns (uint256) {
        return (ts / DURATION) * DURATION;
    }

    function _bribeStart(uint256 ts) internal pure returns (uint256) {
        return (ts / DURATION) * DURATION;
    }

    function writeBalance(uint256 tokenId, uint256 timestamp, uint256 balanceOf_) external {
        uint256 n = numCheckpoints[tokenId];
        checkpoints[tokenId][n] = Checkpoint(timestamp, balanceOf_);
        numCheckpoints[tokenId] = n + 1;
    }

    function writeSupply(uint256 timestamp, uint256 supply) external {
        supplyCheckpoints[supplyNum] = SupplyCheckpoint(timestamp, supply);
        supplyNum += 1;
    }

    function notify(address token, uint256 epochStart, uint256 amount) external {
        tokenRewardsPerEpoch[token][epochStart] = amount;
    }

    function getPriorBalanceIndex(uint256 tokenId, uint256 timestamp) public view returns (uint256) {
        uint256 n = numCheckpoints[tokenId];
        if (n == 0) return 0;
        if (checkpoints[tokenId][0].timestamp > timestamp) return 0;
        uint256 result = 0;
        for (uint256 i = 0; i < n; i++) {
            if (checkpoints[tokenId][i].timestamp <= timestamp) result = i;
        }
        return result;
    }

    function getPriorSupplyIndex(uint256 timestamp) public view returns (uint256) {
        uint256 n = supplyNum;
        if (n == 0) return 0;
        if (supplyCheckpoints[0].timestamp > timestamp) return 0;
        uint256 result = 0;
        for (uint256 i = 0; i < n; i++) {
            if (supplyCheckpoints[i].timestamp <= timestamp) result = i;
        }
        return result;
    }
}

contract ExternalBribe is BribeLedger {
    Token public reward;

    constructor(Token reward_) {
        reward = reward_;
    }

    function earned(address token, uint256 tokenId) public view returns (uint256) {
        uint256 _startTimestamp = lastEarn[token][tokenId];
        if (numCheckpoints[tokenId] == 0) {
            return 0;
        }

        uint256 _startIndex = getPriorBalanceIndex(tokenId, _startTimestamp);
        uint256 _endIndex = numCheckpoints[tokenId] - 1;

        uint256 rewardAmt = 0;
        RewardCheckpoint memory prevRewards;
        PrevData memory _prev;

        prevRewards.timestamp = _bribeStart(_startTimestamp);

        _prev._prevSupply = 1;

        if (_endIndex > 0) {
            // @> VULN: stops at _endIndex - 1, so the reward parked for that checkpoint is never added
            for (uint256 i = _startIndex; i <= _endIndex - 1; i++) {
                _prev._prevTs = checkpoints[tokenId][i].timestamp;
                _prev._prevBal = checkpoints[tokenId][i].balanceOf;
                uint256 _nextEpochStart = _bribeStart(_prev._prevTs);
                if (_nextEpochStart > prevRewards.timestamp) {
                    rewardAmt += prevRewards.balance;
                }

                prevRewards.timestamp = _nextEpochStart;
                _prev._prevSupply = supplyCheckpoints[
                    getPriorSupplyIndex(_nextEpochStart + DURATION)
                ].supply;
                prevRewards.balance =
                    (_prev._prevBal *
                        tokenRewardsPerEpoch[token][_nextEpochStart]) /
                    _prev._prevSupply;
            }
        }

        Checkpoint memory _cp0 = checkpoints[tokenId][_endIndex];
        (_prev._prevTs, _prev._prevBal) = (_cp0.timestamp, _cp0.balanceOf);

        uint256 _lastEpochStart = _bribeStart(_prev._prevTs);
        uint256 _lastEpochEnd = _lastEpochStart + DURATION;

        if (
            block.timestamp > _lastEpochEnd && _startTimestamp < _lastEpochEnd
        ) {
            SupplyCheckpoint memory _scp0 = supplyCheckpoints[
                getPriorSupplyIndex(_lastEpochEnd)
            ];
            _prev._prevSupply = _scp0.supply;
            rewardAmt += (_prev._prevBal *
                    tokenRewardsPerEpoch[token][_lastEpochStart]) /
                _prev._prevSupply;
        }

        return rewardAmt;
    }

    function getReward(address token, uint256 tokenId) external returns (uint256 paid) {
        paid = earned(token, tokenId);
        lastEarn[token][tokenId] = block.timestamp;
        if (paid != 0) {
            Token(token).transfer(msg.sender, paid);
        }
    }
}

contract ExternalBribeFixed is BribeLedger {
    Token public reward;

    constructor(Token reward_) {
        reward = reward_;
    }

    function earned(address token, uint256 tokenId) public view returns (uint256) {
        uint256 _startTimestamp = lastEarn[token][tokenId];
        if (numCheckpoints[tokenId] == 0) {
            return 0;
        }

        uint256 _startIndex = getPriorBalanceIndex(tokenId, _startTimestamp);
        uint256 _endIndex = numCheckpoints[tokenId] - 1;

        uint256 rewardAmt = 0;
        RewardCheckpoint memory prevRewards;
        PrevData memory _prev;

        prevRewards.timestamp = _bribeStart(_startTimestamp);
        _prev._prevSupply = 1;

        if (_endIndex > 0) {
            for (uint256 i = _startIndex; i <= _endIndex; i++) {
                _prev._prevTs = checkpoints[tokenId][i].timestamp;
                _prev._prevBal = checkpoints[tokenId][i].balanceOf;
                uint256 _nextEpochStart = _bribeStart(_prev._prevTs);
                if (_nextEpochStart > prevRewards.timestamp) {
                    rewardAmt += prevRewards.balance;
                }

                prevRewards.timestamp = _nextEpochStart;
                _prev._prevSupply = supplyCheckpoints[
                    getPriorSupplyIndex(_nextEpochStart + DURATION)
                ].supply;
                prevRewards.balance =
                    (_prev._prevBal *
                        tokenRewardsPerEpoch[token][_nextEpochStart]) /
                    _prev._prevSupply;
            }
        }

        Checkpoint memory _cp0 = checkpoints[tokenId][_endIndex];
        (_prev._prevTs, _prev._prevBal) = (_cp0.timestamp, _cp0.balanceOf);

        uint256 _lastEpochStart = _bribeStart(_prev._prevTs);
        uint256 _lastEpochEnd = _lastEpochStart + DURATION;

        if (block.timestamp > _lastEpochEnd && _startTimestamp < _lastEpochEnd) {
            SupplyCheckpoint memory _scp0 = supplyCheckpoints[getPriorSupplyIndex(_lastEpochEnd)];
            _prev._prevSupply = _scp0.supply;
            rewardAmt += (_prev._prevBal * tokenRewardsPerEpoch[token][_lastEpochStart]) / _prev._prevSupply;
        }

        return rewardAmt;
    }

    function getReward(address token, uint256 tokenId) external returns (uint256 paid) {
        paid = earned(token, tokenId);
        lastEarn[token][tokenId] = block.timestamp;
        if (paid != 0) Token(token).transfer(msg.sender, paid);
    }
}

contract Exploit {
    uint256 public constant TOKEN_ID = 1;
    uint256 public constant VOTES = 100 ether;
    uint256 public constant OWED = 100 ether;

    Token public reward; // nonce 1
    ExternalBribe public bribe; // nonce 2

    uint256 public shouldGet;
    uint256 public got;
    uint256 public paid;
    uint256 public leftInBribe;

    constructor() {
        reward = new Token();
        bribe = new ExternalBribe(reward);
    }

    function run() external {
        uint256 epochNow = bribe.bribeStart(block.timestamp);
        uint256 prevEpoch = epochNow - bribe.DURATION();
        require(prevEpoch > 0, "clock");

        bribe.writeBalance(TOKEN_ID, prevEpoch, VOTES);
        bribe.writeBalance(TOKEN_ID, epochNow, VOTES);
        bribe.writeSupply(epochNow, VOTES);
        bribe.notify(address(reward), prevEpoch, OWED);
        reward.mint(address(bribe), OWED);

        shouldGet = OWED;
        got = bribe.earned(address(reward), TOKEN_ID);
        paid = bribe.getReward(address(reward), TOKEN_ID);
        leftInBribe = reward.balanceOf(address(bribe));

        require(shouldGet == 100 ether, "stated amount");
        require(got == 0, "earned was not 0");
        require(paid == 0, "user was paid");
        require(leftInBribe == 100 ether, "100 did not stay");
        require(reward.balanceOf(address(this)) == 0, "user balance");
    }
}
