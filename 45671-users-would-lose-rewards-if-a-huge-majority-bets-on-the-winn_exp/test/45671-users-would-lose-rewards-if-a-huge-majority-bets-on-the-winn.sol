// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*  Xyro — UpDown rate rounds to 0 when the winning side is tiny (Zokyo, 45671)
    SYNTHETIC, cheatcode-free reduction.
    Root cause: calculateUpDownRate scales both pots by 10**decimals and then
    divides the net losing pot by the net winning pot in FEE_DENOMINATOR units.
    100 vs 100_000_000 rounds the rate to 0, so winners are paid deposit minus
    fee and none of the losing pot. Formula preserved (@> VULN). */

contract Token {
    string public name = "XYRO";
    string public symbol = "XYRO";
    uint8 public decimals = 18;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 a) external { balanceOf[to] += a; }

    function approve(address s, uint256 a) external returns (bool) {
        allowance[msg.sender][s] = a;
        return true;
    }

    function transfer(address to, uint256 a) external returns (bool) {
        _move(msg.sender, to, a);
        return true;
    }

    function transferFrom(address from, address to, uint256 a) external returns (bool) {
        uint256 al = allowance[from][msg.sender];
        if (al != type(uint256).max) allowance[from][msg.sender] = al - a;
        _move(from, to, a);
        return true;
    }

    function _move(address from, address to, uint256 a) internal {
        require(balanceOf[from] >= a, "bal");
        balanceOf[from] -= a;
        balanceOf[to] += a;
    }
}

contract Treasury {
    uint256 public constant FEE_DENOMINATOR = 10_000;
    uint256 public fee = 100; // 1%
    Token public token;
    uint256 public totalDepositsUp;
    uint256 public totalDepositsDown;
    uint256 public collectedFee;
    uint256 public lastRate;
    uint256 public lastPayout;
    mapping(address => uint256) public depositAmounts;

    constructor(Token _token) { token = _token; }

    function deposit(bool down, address who, uint256 amount) external {
        uint256 tokens = amount * 10 ** token.decimals();
        require(token.transferFrom(who, address(this), tokens), "in");
        if (down) {
            totalDepositsDown += amount;
            depositAmounts[who] = amount;
        } else {
            totalDepositsUp += amount;
        }
    }

    function finalize(address winner) external {
        uint256 finalRate = calculateUpDownRate(totalDepositsUp, totalDepositsDown, fee); // STORY4
        lastRate = finalRate;
        distributeWithoutFee(finalRate, winner, depositAmounts[winner]);
    }

    function calculateUpDownRate(uint256 lostTeamTotal, uint256 wonTeamTotal, uint256 updownFee)
        public
        returns (uint256 rate)
    {
        lostTeamTotal *= 10 ** token.decimals(); // STORY5
        wonTeamTotal *= 10 ** token.decimals();
        uint256 lostTeamFee = (lostTeamTotal * updownFee) / FEE_DENOMINATOR;
        uint256 wonTeamFee = (wonTeamTotal * updownFee) / FEE_DENOMINATOR;
        collectedFee += lostTeamFee + wonTeamFee;
        rate = ((lostTeamTotal - lostTeamFee) * FEE_DENOMINATOR) / (wonTeamTotal - wonTeamFee); // @> VULN: rounds to 0
        // FIX: scale the numerator by an extra 1e18 before dividing, and divide the payout by that same 1e18
    }

    function distributeWithoutFee(uint256 rate, address to, uint256 initialDeposit) public {
        initialDeposit *= 10 ** token.decimals();
        uint256 withdrawnFees = (initialDeposit * fee) / FEE_DENOMINATOR;
        uint256 wonAmount = (initialDeposit - withdrawnFees) + ((initialDeposit - withdrawnFees) * rate) / FEE_DENOMINATOR; // STORY6
        lastPayout = wonAmount;
        require(token.transfer(to, wonAmount), "pay");
    }

    /// Same inputs, extra 1e18 in the numerator. Not called by run().
    function calculateUpDownRateFixed(uint256 lost, uint256 won, uint256 updownFee) external view returns (uint256 rate) {
        lost *= 10 ** token.decimals();
        won *= 10 ** token.decimals();
        uint256 lostFee = (lost * updownFee) / FEE_DENOMINATOR;
        uint256 wonFee = (won * updownFee) / FEE_DENOMINATOR;
        rate = ((lost - lostFee) * FEE_DENOMINATOR * 1e18) / (won - wonFee);
    }
}

contract Side {
    function fund(Treasury t, Token token, bool down, uint256 amount) external {
        uint256 tokens = amount * 10 ** token.decimals();
        token.approve(address(t), tokens);
        t.deposit(down, address(this), amount);
    }
}

contract Exploit {
    Token public token; // nonce 1
    Treasury public treasury; // nonce 2
    Side public whale; // nonce 3
    Side public winner; // nonce 4
    // Title case: the huge majority is on the winning side, so lost/won rounds to 0.
    uint256 public constant LOSER = 100;
    uint256 public constant WINNER = 100_000_000;

    constructor() {
        token = new Token();
        treasury = new Treasury(token);
        whale = new Side();
        winner = new Side();
        token.mint(address(whale), LOSER * 1e18);
        token.mint(address(winner), WINNER * 1e18);
    }

    function run() external {
        whale.fund(treasury, token, false, LOSER); // STORY1 up side, the loser
        winner.fund(treasury, token, true, WINNER); // STORY2 down side, the winner
        treasury.finalize(address(winner)); // STORY3
        require(treasury.lastRate() == 0, "rate");
        require(treasury.lastPayout() == 99_000_000 ether, "payout");
        require(token.balanceOf(address(winner)) == 99_000_000 ether, "winner");
        require(token.balanceOf(address(treasury)) == 1_000_100 ether, "stuck");
    }
}
