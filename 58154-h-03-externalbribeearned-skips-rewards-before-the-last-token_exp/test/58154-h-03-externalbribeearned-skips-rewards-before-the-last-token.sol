// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

// ─────────────────────────────────────────────────────────────────────────────
// Synthetic, self-contained reproduction of KittenSwap finding 58154 (H-03):
// "`ExternalBribe.earned` skips rewards before the last `tokenId` checkpoint".
//
// Real audited source (Solidly/Velodrome-style `ExternalBribe`). The vulnerable
// `earned` function is reproduced VERBATIM from the finding's embedded snippet;
// the vulnerable line is marked @>:
//   protocol KittenSwap (2025-05-07)
//   contract ExternalBribe  (earned / getPriorBalanceIndex / getPriorSupplyIndex / _bribeStart)
//   report   github.com/pashov/audits/blob/master/team/md/KittenSwap-security-review_2025-05-07.md
//
// Root cause: `earned` accumulates a checkpoint's epoch reward on the FOLLOWING
// loop iteration (it is lagged one step: `reward += prevRewards.balance` fires
// at the START of the next iteration, and `prevRewards.balance` for checkpoint
// `i` is only computed at the END of iteration `i`). The loop bound is
// `i <= _endIndex - 1` (the @> line) instead of `i <= _endIndex`, so the reward
// computed for the checkpoint at index `_endIndex - 1` is COMPUTED but NEVER
// ADDED — the post-loop block handles only `_endIndex` itself. One full epoch of
// a voter's bribe rewards is therefore silently skipped on every call, and
// because `earned` is the sole accounting source those rewards are permanently
// unclaimable.
//
// `earnedFixed` below is byte-identical to `earned` except for the single
// recommended one-character fix (`i <= _endIndex`); it is included ONLY as a
// correct reference to mechanically quantify the skipped epoch. Non-vulnerable
// dependencies (ERC20 reward token, ve balance/supply checkpoints, cross-epoch
// bribe deposits) are faithful minimal doubles with real transfers and real
// accounting — the skipped amount corresponds to real reward tokens funded into
// the bribe that the voter's `earned` will never account for.
// ─────────────────────────────────────────────────────────────────────────────

/// @dev Faithful minimal ERC20 double for the bribe/reward token.
contract RewardToken {
    string public name = "KittenSwap Bribe";
    string public symbol = "KITTEN";
    uint8 public constant decimals = 18;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply += amount;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        uint256 a = allowance[from][msg.sender];
        if (a != type(uint256).max) allowance[from][msg.sender] = a - amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// VULNERABLE contract — `earned` (and the checkpoint helpers it relies on) is
// reproduced VERBATIM from the audited KittenSwap `ExternalBribe`.
// ─────────────────────────────────────────────────────────────────────────────
contract ExternalBribe {
    // reused struct to avoid stack-too-deep (as in the audited source)
    struct Checkpoint {
        uint timestamp;
        uint balanceOf;
    }
    struct SupplyCheckpoint {
        uint timestamp;
        uint supply;
    }
    struct RewardCheckpoint {
        uint timestamp;
        uint balance;
    }
    struct Prev {
        uint _prevTs;
        uint _prevBal;
        uint _prevSupply;
    }

    uint public constant DURATION = 7 days; // rewards are released over 7 days

    // tokenId => checkpoint index => Checkpoint (ve voting balance)
    mapping(uint => mapping(uint => Checkpoint)) public checkpoints;
    mapping(uint => uint) public numCheckpoints;
    // checkpoint index => SupplyCheckpoint (total ve supply)
    mapping(uint => SupplyCheckpoint) public supplyCheckpoints;
    uint public supplyNumCheckpoints;

    // token => tokenId => last claim timestamp
    mapping(address => mapping(uint => uint)) public lastEarn;
    // token => epochStart => reward amount notified for that epoch
    mapping(address => mapping(uint => uint)) public tokenRewardsPerEpoch;

    // ── VERBATIM: binary-search checkpoint helpers from the audited source ──
    function getPriorBalanceIndex(uint tokenId, uint timestamp) public view returns (uint) {
        uint nCheckpoints = numCheckpoints[tokenId];
        if (nCheckpoints == 0) {
            return 0;
        }
        // First check most recent balance
        if (checkpoints[tokenId][nCheckpoints - 1].timestamp <= timestamp) {
            return (nCheckpoints - 1);
        }
        // Next check implicit zero balance
        if (checkpoints[tokenId][0].timestamp > timestamp) {
            return 0;
        }
        uint lower = 0;
        uint upper = nCheckpoints - 1;
        while (upper > lower) {
            uint center = upper - (upper - lower) / 2; // ceil, avoiding overflow
            Checkpoint memory cp = checkpoints[tokenId][center];
            if (cp.timestamp == timestamp) {
                return center;
            } else if (cp.timestamp < timestamp) {
                lower = center;
            } else {
                upper = center - 1;
            }
        }
        return lower;
    }

    function getPriorSupplyIndex(uint timestamp) public view returns (uint) {
        uint nCheckpoints = supplyNumCheckpoints;
        if (nCheckpoints == 0) {
            return 0;
        }
        // First check most recent balance
        if (supplyCheckpoints[nCheckpoints - 1].timestamp <= timestamp) {
            return (nCheckpoints - 1);
        }
        // Next check implicit zero balance
        if (supplyCheckpoints[0].timestamp > timestamp) {
            return 0;
        }
        uint lower = 0;
        uint upper = nCheckpoints - 1;
        while (upper > lower) {
            uint center = upper - (upper - lower) / 2; // ceil, avoiding overflow
            SupplyCheckpoint memory cp = supplyCheckpoints[center];
            if (cp.timestamp == timestamp) {
                return center;
            } else if (cp.timestamp < timestamp) {
                lower = center;
            } else {
                upper = center - 1;
            }
        }
        return lower;
    }

    function _bribeStart(uint timestamp) internal pure returns (uint) {
        return timestamp - (timestamp % (7 days));
    }

    // ── VERBATIM: the vulnerable `earned` from the finding's embedded snippet ──
    // (reporter-added console.log debug lines omitted; all reward arithmetic and
    //  the loop bound are byte-for-byte the audited source.)
    function earned(address token, uint tokenId) public view returns (uint) {
        uint _startTimestamp = lastEarn[token][tokenId];
        if (numCheckpoints[tokenId] == 0) {
            return 0;
        }

        uint _startIndex = getPriorBalanceIndex(tokenId, _startTimestamp);
        uint _endIndex = numCheckpoints[tokenId] - 1;

        uint reward = 0;
        // you only earn once per epoch (after it's over)
        RewardCheckpoint memory prevRewards;
        Prev memory _prev;

        prevRewards.timestamp = _bribeStart(_startTimestamp);

        _prev._prevSupply = 1;

        if (_endIndex > 0) {
            for (uint i = _startIndex; i <= _endIndex - 1; i++) { // @> VULN: bound is `_endIndex - 1`; the reward computed for checkpoint `_endIndex - 1` is never added, so one full epoch is skipped (should be `i <= _endIndex`)
                _prev._prevTs = checkpoints[tokenId][i].timestamp;
                _prev._prevBal = checkpoints[tokenId][i].balanceOf;
                uint _nextEpochStart = _bribeStart(_prev._prevTs);
                // check that you've earned it
                // this won't happen until a week has passed
                if (_nextEpochStart > prevRewards.timestamp) {
                    reward += prevRewards.balance;
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

        uint _lastEpochStart = _bribeStart(_prev._prevTs);
        uint _lastEpochEnd = _lastEpochStart + DURATION;

        if (
            block.timestamp > _lastEpochEnd && _startTimestamp < _lastEpochEnd
        ) {
            SupplyCheckpoint memory _scp0 = supplyCheckpoints[
                getPriorSupplyIndex(_lastEpochEnd)
            ];
            _prev._prevSupply = _scp0.supply;
            reward += (_prev._prevBal *
                    tokenRewardsPerEpoch[token][_lastEpochStart]) /
                _prev._prevSupply;
        }

        return reward;
    }

    // ── CORRECT REFERENCE: identical to `earned` except the single recommended
    //    one-character fix (`i <= _endIndex`). Used only to quantify the skipped
    //    epoch; NOT part of the audited source. ──
    function earnedFixed(address token, uint tokenId) public view returns (uint) {
        uint _startTimestamp = lastEarn[token][tokenId];
        if (numCheckpoints[tokenId] == 0) {
            return 0;
        }

        uint _startIndex = getPriorBalanceIndex(tokenId, _startTimestamp);
        uint _endIndex = numCheckpoints[tokenId] - 1;

        uint reward = 0;
        RewardCheckpoint memory prevRewards;
        Prev memory _prev;

        prevRewards.timestamp = _bribeStart(_startTimestamp);

        _prev._prevSupply = 1;

        if (_endIndex > 0) {
            for (uint i = _startIndex; i <= _endIndex; i++) { // FIX: include _endIndex
                _prev._prevTs = checkpoints[tokenId][i].timestamp;
                _prev._prevBal = checkpoints[tokenId][i].balanceOf;
                uint _nextEpochStart = _bribeStart(_prev._prevTs);
                if (_nextEpochStart > prevRewards.timestamp) {
                    reward += prevRewards.balance;
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

        uint _lastEpochStart = _bribeStart(_prev._prevTs);
        uint _lastEpochEnd = _lastEpochStart + DURATION;

        if (
            block.timestamp > _lastEpochEnd && _startTimestamp < _lastEpochEnd
        ) {
            SupplyCheckpoint memory _scp0 = supplyCheckpoints[
                getPriorSupplyIndex(_lastEpochEnd)
            ];
            _prev._prevSupply = _scp0.supply;
            reward += (_prev._prevBal *
                    tokenRewardsPerEpoch[token][_lastEpochStart]) /
                _prev._prevSupply;
        }

        return reward;
    }

    // ── faithful minimal doubles for cross-epoch setup (the finding's PoC uses
    //    vm.warp + deposit/notifyRewardAmount across epochs; these parameterize
    //    the epoch instead so a single tx can seed the same state). Real token
    //    transfers, real accounting. ──

    RewardToken internal rewardTokenRef;

    constructor(RewardToken reward_) {
        rewardTokenRef = reward_;
    }

    /// @notice Faithful double of a ve-balance checkpoint write for `tokenId`.
    function seedBalanceCheckpoint(uint tokenId, uint timestamp, uint balanceOf_) external {
        uint n = numCheckpoints[tokenId];
        checkpoints[tokenId][n] = Checkpoint(timestamp, balanceOf_);
        numCheckpoints[tokenId] = n + 1;
    }

    /// @notice Faithful double of a total-supply checkpoint write.
    function seedSupplyCheckpoint(uint timestamp, uint supply_) external {
        uint n = supplyNumCheckpoints;
        supplyCheckpoints[n] = SupplyCheckpoint(timestamp, supply_);
        supplyNumCheckpoints = n + 1;
    }

    /// @notice Faithful double of `notifyRewardAmount` for a specific epoch:
    ///         pulls real reward tokens into the bribe and credits the epoch.
    function notifyRewardAmountAt(address token, uint epochStart, uint amount) external {
        require(amount > 0);
        RewardToken(token).transferFrom(msg.sender, address(this), amount);
        tokenRewardsPerEpoch[token][epochStart] += amount;
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Exploit driver: a single voter (tokenId 1) holds voting weight across three
// consecutive epochs, each funded with an identical 100e18 bribe. The verbatim
// `earned` skips the middle epoch's reward entirely, undercounting the voter's
// claimable rewards by exactly one full epoch (100e18) versus the correct
// reference — a permanent loss since `earned` is the only accounting source.
// The skipped magnitude is minted to SINK as the quantified loss marker.
// ─────────────────────────────────────────────────────────────────────────────
contract Exploit {
    address internal constant SINK = 0x000000000000000000000000000000000000D00d;

    RewardToken public reward;    // child nonce 1 (profit / marker token)
    ExternalBribe public bribe;   // child nonce 2 (VULN)

    uint256 public buggyEarned;   // what the vulnerable `earned` reports
    uint256 public correctEarned; // what a correct loop would report
    uint256 public skippedReward; // permanently-skipped epoch reward
    uint256 public strandedInBribe; // real bribe tokens the voter can never account for

    uint256 internal constant TOKEN_ID = 1;
    uint256 internal constant VE_BAL = 1e18;      // voter's ve voting balance
    uint256 internal constant BRIBE = 100e18;     // bribe deposited per epoch
    uint256 internal constant WEEK = 7 days;      // 604800
    uint256 internal constant BASE = 100 * (7 days); // a clean epoch boundary

    constructor() {
        reward = new RewardToken();           // child nonce 1
        bribe = new ExternalBribe(reward);    // child nonce 2 (VULN)
    }

    function run() external {
        uint256 e1 = BASE;              // epoch 1 start
        uint256 e2 = BASE + WEEK;       // epoch 2 start  (this is the skipped middle epoch)
        uint256 e3 = BASE + 2 * WEEK;   // epoch 3 start

        // 1) fund three consecutive epochs with identical real bribes (100e18 each)
        reward.mint(address(this), 3 * BRIBE);
        reward.approve(address(bribe), type(uint256).max);
        bribe.notifyRewardAmountAt(address(reward), e1, BRIBE);
        bribe.notifyRewardAmountAt(address(reward), e2, BRIBE);
        bribe.notifyRewardAmountAt(address(reward), e3, BRIBE);

        // 2) the voter (tokenId 1) holds VE_BAL across all three epochs -> one
        //    balance checkpoint per epoch, and matching total-supply checkpoints
        //    (voter is the only participant, so supply == VE_BAL).
        bribe.seedBalanceCheckpoint(TOKEN_ID, e1 + 100, VE_BAL);
        bribe.seedSupplyCheckpoint(e1 + 100, VE_BAL);
        bribe.seedBalanceCheckpoint(TOKEN_ID, e2 + 100, VE_BAL);
        bribe.seedSupplyCheckpoint(e2 + 100, VE_BAL);
        bribe.seedBalanceCheckpoint(TOKEN_ID, e3 + 100, VE_BAL);
        bribe.seedSupplyCheckpoint(e3 + 100, VE_BAL);

        // 3) read the vulnerable accounting vs a correct loop
        buggyEarned = bribe.earned(address(reward), TOKEN_ID);
        correctEarned = bribe.earnedFixed(address(reward), TOKEN_ID);
        skippedReward = correctEarned - buggyEarned;

        // per-epoch reward = VE_BAL * BRIBE / supply(=VE_BAL) = BRIBE = 100e18.
        // the checkpoint at index _endIndex-1 (the middle epoch e2) is computed
        // but never added, so exactly one epoch (100e18) is lost.
        strandedInBribe = reward.balanceOf(address(bribe)); // 300e18 of real bribes sit here

        // mark the permanently-skipped reward magnitude at SINK
        reward.mint(SINK, skippedReward);

        // harm: the voter's own accounting silently drops a full epoch of bribes
        require(buggyEarned < correctEarned, "no shortfall in earned()");
        require(skippedReward == BRIBE, "skipped amount is not exactly one epoch");
        require(strandedInBribe >= skippedReward, "skipped reward not backed by real tokens");
        require(reward.balanceOf(SINK) == skippedReward, "loss marker mismatch");
    }
}
