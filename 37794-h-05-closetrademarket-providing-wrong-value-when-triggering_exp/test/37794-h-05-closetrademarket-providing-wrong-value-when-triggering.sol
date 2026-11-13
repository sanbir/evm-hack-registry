// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*  Gains Network gTrade — Pashov, February review published 2024-09.
    closeTradeMarket passes
        (collateralAmount * leverage) / 1e3 / precisionDelta / PRECISION
    into getPrice. For 1000 USDC at 10x that extra division is 0, so the
    Chainlink node fee is 0 instead of 1e11 wei of LINK. Settlement refuses
    an unpaid request and the 1000 USDC stays in the trading contract.
    The control passes collateral precision and the USDC is returned.
*/

contract Token {
    string public symbol;
    uint8 public immutable decimals;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    constructor(string memory sym, uint8 dec) {
        symbol = sym;
        decimals = dec;
    }

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
        allowance[from][msg.sender] -= amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

contract Trading {
    uint256 public constant PRECISION = 1e10;
    uint256 public constant PRECISION_DELTA = 1e12;
    uint256 public constant LINK_PRICE_USD = 10e8;
    uint256 public constant ORACLE_FEE_P = 100;
    uint256 public constant COLLATERAL = 1000e6;
    uint256 public constant LEVERAGE = 10_000;

    Token public usdc;
    Token public link;
    address public oracle;
    address public trader;
    uint256 public linkPaid;
    bool public pending;
    bool public open;
    uint256 public collateralAmount;
    uint256 public leverage;

    constructor(Token _usdc, Token _link, address _oracle) {
        usdc = _usdc;
        link = _link;
        oracle = _oracle;
        collateralAmount = COLLATERAL;
        leverage = LEVERAGE;
    }

    function getLinkFee(uint256 positionSizeCollateral) public pure returns (uint256) {
        uint256 usd = positionSizeCollateral * PRECISION_DELTA;
        return (ORACLE_FEE_P * usd * 1e8) / LINK_PRICE_USD / PRECISION / 100;
    }

    function fairFee() public pure returns (uint256) {
        return getLinkFee((COLLATERAL * LEVERAGE) / 1e3);
    }

    function openTrade() external {
        require(usdc.transferFrom(msg.sender, address(this), COLLATERAL), "margin");
        trader = msg.sender;
        open = true;
    }

    function closeTradeMarket() external {
        require(open, "open");
        require(trader == msg.sender, "trader");
        uint256 positionSize = (collateralAmount * leverage) / 1e3 / PRECISION_DELTA / PRECISION;
        // @> VULN: getPrice is given a notional already divided by precisionDelta and PRECISION, so the LINK fee is 0
        linkPaid = getLinkFee(positionSize);
        if (linkPaid > 0) require(link.transfer(oracle, linkPaid), "link");
        pending = true;
    }

    function settle() external {
        require(pending, "pending");
        require(linkPaid > 0, "unpaid oracle");
        pending = false;
        open = false;
        require(usdc.transfer(trader, COLLATERAL), "usdc");
    }
}

contract TradingFixed {
    uint256 public constant PRECISION = 1e10;
    uint256 public constant PRECISION_DELTA = 1e12;
    uint256 public constant LINK_PRICE_USD = 10e8;
    uint256 public constant ORACLE_FEE_P = 100;
    uint256 public constant COLLATERAL = 1000e6;
    uint256 public constant LEVERAGE = 10_000;

    Token public usdc;
    Token public link;
    address public oracle;
    address public trader;
    uint256 public linkPaid;

    constructor(Token _usdc, Token _link, address _oracle) {
        usdc = _usdc;
        link = _link;
        oracle = _oracle;
    }

    function getLinkFee(uint256 positionSizeCollateral) public pure returns (uint256) {
        uint256 usd = positionSizeCollateral * PRECISION_DELTA;
        return (ORACLE_FEE_P * usd * 1e8) / LINK_PRICE_USD / PRECISION / 100;
    }

    function openTrade() external {
        require(usdc.transferFrom(msg.sender, address(this), COLLATERAL), "margin");
        trader = msg.sender;
    }

    function closeTradeMarket() external {
        uint256 positionSize = (COLLATERAL * LEVERAGE) / 1e3;
        linkPaid = getLinkFee(positionSize);
        require(link.transfer(oracle, linkPaid), "link");
    }

    function settle() external {
        require(linkPaid > 0, "fee");
        require(usdc.transfer(trader, usdc.balanceOf(address(this))), "usdc");
    }
}

contract Exploit {
    Token public usdc;
    Token public link;
    Trading public trading;
    address public oracle;
    uint256 public paid;
    uint256 public fair;
    bool public settleReverted;
    uint256 public locked;

    constructor() {
        usdc = new Token("USDC", 6);
        link = new Token("LINK", 18);
        oracle = address(0x3333333333333333333333333333333333333333);
        trading = new Trading(usdc, link, oracle);
        link.mint(address(trading), 1e11);
        usdc.mint(address(this), 1000e6);
    }

    function run() external {
        fair = trading.fairFee();
        usdc.approve(address(trading), 1000e6);
        trading.openTrade();
        trading.closeTradeMarket();
        paid = trading.linkPaid();
        (bool ok,) = address(trading).call(abi.encodeWithSelector(trading.settle.selector));
        settleReverted = !ok;
        locked = usdc.balanceOf(address(trading));
        require(fair == 1e11, "fair");
        require(paid == 0, "paid");
        require(link.balanceOf(oracle) == 0, "oracle");
        require(settleReverted, "settled");
        require(trading.pending(), "pending");
        require(locked == 1000e6, "locked");
        require(usdc.balanceOf(address(this)) == 0, "user");
    }
}
