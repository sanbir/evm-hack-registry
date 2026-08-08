// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*  Rubicon — [H-10] Some offers can't be cancelled (Code4rena 2023-04-rubicon; #48949)
    SYNTHETIC, cheatcode-free reduction for the EVM Playground.
    Root cause: SimpleMarket.offer (6-arg) creates an offer without inserting it into
    the sorted `_rank` list or the unsorted `_near` list. RubiconMarket.cancel requires
    the offer to be sorted OR successfully `_hide`d from `_near`; both fail, so cancel
    reverts with "can't hide" and the maker's pay_gem remains locked forever.
    Vulnerable cancel path preserved with @> VULN markers. */

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

/// @dev Minimal RubiconMarket: SimpleMarket.offer path + RubiconMarket.cancel path.
contract RubiconMarket {
    struct OfferInfo {
        uint256 pay_amt;
        address pay_gem;
        uint256 buy_amt;
        address buy_gem;
        address owner;
        uint64 timestamp;
    }

    mapping(uint256 => OfferInfo) public offers;
    uint256 public last_offer_id;

    // Sorted book: offer is "sorted" if present in _rank (next != 0 or is best).
    mapping(uint256 => uint256) public _rank; // offerId => next (non-zero means sorted)
    mapping(address => mapping(address => uint256)) public _best;
    // Unsorted book
    mapping(uint256 => uint256) public _near; // offerId => next in unsorted list
    mapping(address => mapping(address => uint256)) public _head; // first unsorted

    event LogMake(uint256 id, address pay_gem, uint256 pay_amt, address buy_gem, uint256 buy_amt, address owner);
    event LogKill(uint256 id);

    /// @notice SimpleMarket-style 6-arg offer — does NOT insert into _rank or _near.
    /// This is the un-overridden SimpleMarket API the finding blames.
    function offer(
        uint256 pay_amt,
        address pay_gem,
        uint256 buy_amt,
        address buy_gem,
        address /* owner_ignored */,
        address /* recipient */
    ) external returns (uint256 id) {
        require(pay_amt > 0 && buy_amt > 0, "dust");
        require(pay_gem != buy_gem, "same gem");
        MockERC20(pay_gem).transferFrom(msg.sender, address(this), pay_amt);
        id = ++last_offer_id;
        offers[id] = OfferInfo({
            pay_amt: pay_amt,
            pay_gem: pay_gem,
            buy_amt: buy_amt,
            buy_gem: buy_gem,
            owner: msg.sender,
            timestamp: uint64(block.timestamp)
        });
        // BUG: SimpleMarket.offer does NOT call _sort / _insert into _rank or _near.
        // Only RubiconMarket's longer offer(...) path would insert into the book.
        emit LogMake(id, pay_gem, pay_amt, buy_gem, buy_amt, msg.sender);
    }

    function isOfferSorted(uint256 id) public view returns (bool) {
        // Sorted iff present in the rank chain (non-zero next) or is the current best.
        OfferInfo memory o = offers[id];
        if (o.pay_amt == 0) return false;
        if (_rank[id] != 0) return true;
        if (_best[o.pay_gem][o.buy_gem] == id) return true;
        return false;
    }

    function _hide(uint256 id) internal returns (bool) {
        // Remove from unsorted list; returns false if not found.
        OfferInfo memory o = offers[id];
        uint256 prev = 0;
        uint256 cur = _head[o.pay_gem][o.buy_gem];
        while (cur != 0) {
            if (cur == id) {
                if (prev == 0) _head[o.pay_gem][o.buy_gem] = _near[cur];
                else _near[prev] = _near[cur];
                _near[cur] = 0;
                return true;
            }
            prev = cur;
            cur = _near[cur];
        }
        return false;
    }

    /// @notice RubiconMarket.cancel — requires sorted OR successfully hidden from unsorted.
    function cancel(uint256 id) external returns (bool success) {
        require(offers[id].owner == msg.sender, "not owner");
        if (isOfferSorted(id)) {
            // would unsort then hide — path not taken for SimpleMarket offers
            _rank[id] = 0;
            if (_best[offers[id].pay_gem][offers[id].buy_gem] == id) {
                _best[offers[id].pay_gem][offers[id].buy_gem] = 0;
            }
        } else {
            // @> VULN: SimpleMarket offers are neither sorted nor on the unsorted list,
            // so _hide returns false and cancel reverts — maker funds stay locked.
            require(_hide(id), "can't hide"); // @> VULN: "can't hide" for unsorted SimpleMarket offers
            // FIX: override SimpleMarket.offer to call the sorted offer(...) path that inserts into _rank.
        }
        // delete and refund (never reached for the vulnerable path)
        OfferInfo memory o = offers[id];
        delete offers[id];
        MockERC20(o.pay_gem).transfer(o.owner, o.pay_amt);
        emit LogKill(id);
        success = true;
    }

    function getOfferPayAmt(uint256 id) external view returns (uint256) {
        return offers[id].pay_amt;
    }
}

/// @dev Maker that places an offer then tries (and fails) to cancel.
contract Maker {
    RubiconMarket public market;
    MockERC20 public payGem;

    constructor(RubiconMarket m, MockERC20 t) {
        market = m;
        payGem = t;
    }

    function placeOffer(uint256 payAmt, address buyGem, uint256 buyAmt) external returns (uint256 id) {
        payGem.approve(address(market), payAmt);
        id = market.offer(payAmt, address(payGem), buyAmt, buyGem, address(this), address(this));
    }

    function tryCancel(uint256 id) external returns (bool ok) {
        // Returns false (does not bubble) when cancel reverts with "can't hide".
        try market.cancel(id) returns (bool) {
            return true;
        } catch {
            return false;
        }
    }
}

contract Exploit {
    MockERC20 public payToken; // CREATE nonce 1
    MockERC20 public buyToken; // CREATE nonce 2
    RubiconMarket public market; // CREATE nonce 3 — vulnerable
    Maker public maker; // CREATE nonce 4

    uint256 public offerId;
    uint256 public constant LOCKED = 90e18;

    constructor() {
        payToken = new MockERC20("Pay", "PAY");
        buyToken = new MockERC20("Buy", "BUY");
        market = new RubiconMarket();
        maker = new Maker(market, payToken);
        payToken.mint(address(maker), LOCKED);
    }

    function run() external {
        // 1. Maker places offer via SimpleMarket 6-arg API (no book insertion).
        offerId = maker.placeOffer(LOCKED, address(buyToken), 100e18);

        // 2. Offer exists and holds the maker's tokens.
        require(market.getOfferPayAmt(offerId) == LOCKED, "offer missing");
        require(payToken.balanceOf(address(market)) == LOCKED, "tokens not locked");

        // 3. Cancel attempt reverts — funds permanently locked.
        bool cancelled = maker.tryCancel(offerId);
        require(!cancelled, "cancel should fail");
        require(payToken.balanceOf(address(market)) == LOCKED, "tokens still locked");
        require(payToken.balanceOf(address(maker)) == 0, "maker not refunded");
        // Harm: maker cannot cancel; pay_gem locked in market forever.
    }
}
