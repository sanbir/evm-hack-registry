// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

/*  Term Finance — cancelling an auction refunds sortedOffers[i].amount for an
    unrevealed offer (Sigma Prime, term1, the loop that calls unlockOfferPartial).
    The offeror locked 5,000 and is paid the revealed offer's 100. 4,900 stays
    in the locker. Refunding unrevealedOffers[i].amount returns all 5,000. */

contract Cash26293 {
    string public name = "Purchase";
    string public symbol = "BUY";
    uint8 public decimals = 18;
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

contract CancelAuction26293 {
    Cash26293 public cash;
    address[1] public unrevealedOfferor;
    uint256[1] public unrevealedAmount;
    uint256[1] public sortedAmount;
    uint256 public count;
    uint256 public lastRefund;

    constructor(Cash26293 c) {
        cash = c;
    }

    function record(address offeror, uint256 unrevealedAmt, uint256 sortedAmt) external {
        unrevealedOfferor[0] = offeror;
        unrevealedAmount[0] = unrevealedAmt;
        sortedAmount[0] = sortedAmt;
        count = 1;
    }

    function _pay(address offeror, uint256 amount) internal returns (uint256) {
        lastRefund = amount;
        if (amount > 0) {
            cash.transfer(offeror, amount);
        }
        return amount;
    }

    function cancel() external returns (uint256 refunded) {
        for (uint256 i = 0; i < count; i++) {
            // @> VULN: sortedOffers[i].amount is refunded. The unrevealed offer's own amount is not.
            refunded = _pay(unrevealedOfferor[i], sortedAmount[i]);
        }
    }
}

contract CancelAuctionFixed26293 {
    Cash26293 public cash;
    address[1] public unrevealedOfferor;
    uint256[1] public unrevealedAmount;
    uint256[1] public sortedAmount;
    uint256 public count;
    uint256 public lastRefund;

    constructor(Cash26293 c) {
        cash = c;
    }

    function record(address offeror, uint256 unrevealedAmt, uint256 sortedAmt) external {
        unrevealedOfferor[0] = offeror;
        unrevealedAmount[0] = unrevealedAmt;
        sortedAmount[0] = sortedAmt;
        count = 1;
    }

    function cancel() external returns (uint256 refunded) {
        for (uint256 i = 0; i < count; i++) {
            uint256 amount = unrevealedAmount[i];
            lastRefund = amount;
            if (amount > 0) {
                cash.transfer(unrevealedOfferor[i], amount);
            }
            refunded = amount;
        }
    }
}

contract Exploit {
    uint256 public constant LOCKED = 5000 ether;
    uint256 public constant REVEALED = 100 ether;

    Cash26293 public cash;
    CancelAuction26293 public auction;
    Cash26293 public cashC;
    CancelAuctionFixed26293 public auctionC;

    uint256 public parked;
    uint256 public refunded;
    uint256 public stuck;
    uint256 public offerorGot;
    uint256 public controlRefunded;
    uint256 public controlLeft;
    uint256 public controlGot;

    function run() external {
        cash = new Cash26293();
        auction = new CancelAuction26293(cash);
        cashC = new Cash26293();
        auctionC = new CancelAuctionFixed26293(cashC);

        cash.mint(address(auction), LOCKED);
        parked = cash.balanceOf(address(auction));
        auction.record(address(this), LOCKED, REVEALED);

        refunded = auction.cancel();
        stuck = cash.balanceOf(address(auction));
        offerorGot = cash.balanceOf(address(this));

        cashC.mint(address(auctionC), LOCKED);
        auctionC.record(address(this), LOCKED, REVEALED);
        controlRefunded = auctionC.cancel();
        controlLeft = cashC.balanceOf(address(auctionC));
        controlGot = cashC.balanceOf(address(this));

        require(parked == LOCKED, "parked");
        require(refunded == REVEALED, "refunded");
        require(stuck == LOCKED - REVEALED, "stuck");
        require(offerorGot == REVEALED, "offeror");
        require(controlRefunded == LOCKED, "control refund");
        require(controlLeft == 0, "control left");
        require(controlGot == LOCKED, "control got");
    }
}
