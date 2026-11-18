// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*  Remora Pledge — uint32 * uint32 overflow in pledge and refundTokens (Cyfrin, Jul 2025)
    SYNTHETIC, cheatcode-free reduction for the EVM Playground.
    Root cause: the product is evaluated in uint32 before the uint256 assignment,
    so any pledge whose pricePerToken * numTokens exceeds type(uint32).max reverts.
    Vulnerable lines preserved verbatim (@> VULN). */

contract MiniToken {
    string public name;
    uint8 public constant decimals = 6;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    constructor(string memory n) {
        name = n;
    }

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount; // S1
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        require(balanceOf[msg.sender] >= amount, "bal");
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        require(balanceOf[from] >= amount, "bal");
        require(allowance[from][msg.sender] >= amount, "allow");
        allowance[from][msg.sender] -= amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

contract PledgeManager {
    MiniToken public immutable stablecoin;
    mapping(address => uint256) public pledgedOf;

    constructor(MiniToken s) {
        stablecoin = s;
    }

    function pledge(address pledger, uint32 pricePerToken, uint32 numTokens) external returns (uint256) {
        uint256 stablecoinAmount = pricePerToken * numTokens; // @> VULN: S3 uint32 product reverts above 4294967295
        stablecoin.transferFrom(pledger, address(this), stablecoinAmount);
        pledgedOf[pledger] += stablecoinAmount;
        return stablecoinAmount;
    }

    function refundTokens(address pledger, uint32 pricePerToken, uint32 numTokens) external returns (uint256) {
        uint256 refundAmount = numTokens * pricePerToken; // @> VULN: S5 TODO overflow check, same uint32 product
        pledgedOf[pledger] -= refundAmount;
        stablecoin.transfer(pledger, refundAmount);
        return refundAmount;
    }
}

contract PledgeManagerFixed {
    MiniToken public immutable stablecoin;
    mapping(address => uint256) public pledgedOf;

    constructor(MiniToken s) {
        stablecoin = s;
    }

    function pledge(address pledger, uint32 pricePerToken, uint32 numTokens) external returns (uint256) {
        uint256 stablecoinAmount = uint256(pricePerToken) * numTokens;
        stablecoin.transferFrom(pledger, address(this), stablecoinAmount);
        pledgedOf[pledger] += stablecoinAmount;
        return stablecoinAmount;
    }
}

contract Exploit {
    MiniToken public stable; // CREATE nonce 1
    PledgeManager public manager; // CREATE nonce 2

    uint32 internal constant PRICE = 1_000_000;
    uint32 internal constant SMALL = 4;
    uint32 internal constant LARGE = 5000;

    bool public largeReverted;
    bool public refundReverted;
    uint256 public deniedAmount;
    uint256 public userLeft;

    constructor() {
        stable = new MiniToken("USDC");
        manager = new PledgeManager(stable);
        deniedAmount = uint256(PRICE) * uint256(LARGE);
        stable.mint(address(this), deniedAmount + uint256(PRICE) * uint256(SMALL));
    }

    function run() external {
        stable.approve(address(manager), type(uint256).max); // S2
        manager.pledge(address(this), PRICE, SMALL);
        try manager.pledge(address(this), PRICE, LARGE) returns (uint256) {
            largeReverted = false;
        } catch {
            largeReverted = true; // S4
        }
        try manager.refundTokens(address(this), PRICE, LARGE) returns (uint256) {
            refundReverted = false;
        } catch {
            refundReverted = true;
        }
        userLeft = stable.balanceOf(address(this)); // S6
        require(largeReverted, "large pledge must revert");
        require(refundReverted, "matching refund must revert");
        require(deniedAmount == 5_000_000_000, "denied 5000 USDC");
        require(userLeft == deniedAmount, "user still holds the denied pledge");
        require(deniedAmount > uint256(type(uint32).max), "product exceeds uint32");
    }
}
