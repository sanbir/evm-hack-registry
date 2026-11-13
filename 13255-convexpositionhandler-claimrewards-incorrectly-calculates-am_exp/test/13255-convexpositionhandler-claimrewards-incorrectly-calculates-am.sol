// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

/*  Brahma ConvexPositionHandler — _claimRewards unstakes ETH-denominated LP
    (ConsenSys Diligence, Brahma Fi, May 2022).
    SYNTHETIC, cheatcode-free reduction.
    yieldEarned = (currentSharePrice - prevSharePrice) * totalLpBalance
    is an ETH amount. Dividing by 1e18 does not convert it to LP.
    The fair LP amount is yieldEarned / currentSharePrice.
    With price 2e18, prev 1e18, and 10 LP, the bug unstakes 10 LP.
    The fair unstake is 5 LP. */

contract LpToken {
    string public name = "Curve LP";
    string public symbol = "LP";
    uint8 public decimals = 18;
    mapping(address => uint256) public balanceOf;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

contract BuggyHandler {
    uint256 public constant NORMALIZATION_FACTOR = 1e18;
    LpToken public lp;
    address public yieldSink;
    uint256 public prevSharePrice;
    uint256 public currentSharePrice;
    uint256 public paid;

    constructor(address _lp, address _sink, uint256 _prev, uint256 _current) {
        lp = LpToken(_lp);
        yieldSink = _sink;
        prevSharePrice = _prev;
        currentSharePrice = _current;
    }

    function claimRewards() external returns (uint256 lpTokenEarned) {
        uint256 price = currentSharePrice;
        if (price > prevSharePrice) {
            uint256 totalLpBalance = lp.balanceOf(address(this));
            uint256 yieldEarned = (price - prevSharePrice) * totalLpBalance;
            // @> VULN: yieldEarned is ETH-scaled; dividing by 1e18 still unstakes ETH units, not LP
            lpTokenEarned = yieldEarned / NORMALIZATION_FACTOR; lp.transfer(yieldSink, lpTokenEarned);
            paid = lpTokenEarned;
        }
    }
}

contract FixedHandler {
    LpToken public lp;
    address public yieldSink;
    uint256 public prevSharePrice;
    uint256 public currentSharePrice;
    uint256 public paid;

    constructor(address _lp, address _sink, uint256 _prev, uint256 _current) {
        lp = LpToken(_lp);
        yieldSink = _sink;
        prevSharePrice = _prev;
        currentSharePrice = _current;
    }

    function claimRewards() external returns (uint256 lpTokenEarned) {
        uint256 price = currentSharePrice;
        if (price > prevSharePrice) {
            uint256 totalLpBalance = lp.balanceOf(address(this));
            uint256 yieldEarned = (price - prevSharePrice) * totalLpBalance;
            lpTokenEarned = yieldEarned / price;
            lp.transfer(yieldSink, lpTokenEarned);
            paid = lpTokenEarned;
        }
    }
}

contract Exploit {
    uint256 public constant PREV = 1e18;
    uint256 public constant CURRENT = 2e18;
    uint256 public constant LP = 10e18;
    uint256 public constant FAIR = 5e18;

    LpToken public lp;
    BuggyHandler public buggy;
    FixedHandler public fixedHandler;
    address public sink;
    address public controlSink;

    uint256 public paid;
    uint256 public fairPaid;
    uint256 public buggyLeft;
    uint256 public fixedLeft;

    constructor() {
        lp = new LpToken();
        sink = address(new Sink());
        controlSink = address(new Sink());
        buggy = new BuggyHandler(address(lp), sink, PREV, CURRENT);
        fixedHandler = new FixedHandler(address(lp), controlSink, PREV, CURRENT);
        lp.mint(address(buggy), LP);
        lp.mint(address(fixedHandler), LP);
    }

    function run() external {
        paid = buggy.claimRewards();
        fairPaid = fixedHandler.claimRewards();
        buggyLeft = lp.balanceOf(address(buggy));
        fixedLeft = lp.balanceOf(address(fixedHandler));
        require(paid == LP, "paid");
        require(fairPaid == FAIR, "fair");
        require(paid > fairPaid, "not greater");
        require(buggyLeft == 0, "buggy left");
        require(fixedLeft == FAIR, "fixed left");
        require(lp.balanceOf(sink) == paid, "sink");
        require(lp.balanceOf(controlSink) == FAIR, "control sink");
    }
}

contract Sink {}
