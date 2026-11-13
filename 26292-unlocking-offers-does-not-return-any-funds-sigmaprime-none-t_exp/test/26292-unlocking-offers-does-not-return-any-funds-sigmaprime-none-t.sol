// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

/*  Term Finance — TermAuctionOfferLocker.unlockOffer reads a storage pointer
    after delete (Sigma Prime, term1). The offer is removed and the amount
    that is returned is 0, so the purchase tokens stay in the locker.
    Copying the amount to a memory value before the delete returns them. */

contract Cash26292 {
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

contract OfferLocker26292 {
    struct Offer {
        address offeror;
        uint256 amount;
    }

    Cash26292 public cash;
    mapping(uint256 => Offer) public offers;
    uint256 public recorded;
    uint256 public lastPaid;

    constructor(Cash26292 c) {
        cash = c;
    }

    function lock(uint256 id, address offeror, uint256 amount) external {
        offers[id] = Offer(offeror, amount);
        recorded = amount;
    }

    function touch(uint256 amount) external {
        lastPaid = amount;
    }

    function unlockOffer(uint256 id, address offeror) external returns (uint256 paid) {
        Offer storage offerToUnlock = offers[id];
        delete offers[id];
        uint256 cleared = offerToUnlock.amount;
        // @> VULN: offerToUnlock is a storage pointer. delete already cleared it, so the amount handed to the return is 0.
        this.touch(cleared);
        if (cleared > 0) {
            cash.transfer(offeror, cleared);
        }
        paid = cleared;
    }
}

contract OfferLockerFixed26292 {
    struct Offer {
        address offeror;
        uint256 amount;
    }

    Cash26292 public cash;
    mapping(uint256 => Offer) public offers;
    uint256 public lastPaid;

    constructor(Cash26292 c) {
        cash = c;
    }

    function lock(uint256 id, address offeror, uint256 amount) external {
        offers[id] = Offer(offeror, amount);
    }

    function unlockOffer(uint256 id, address offeror) external returns (uint256 paid) {
        uint256 amountToUnlock = offers[id].amount;
        delete offers[id];
        lastPaid = amountToUnlock;
        if (amountToUnlock > 0) {
            cash.transfer(offeror, amountToUnlock);
        }
        paid = amountToUnlock;
    }
}

contract Exploit {
    uint256 public constant N = 1000 ether;

    Cash26292 public cash;
    OfferLocker26292 public locker;
    Cash26292 public cashC;
    OfferLockerFixed26292 public lockerC;

    uint256 public deposited;
    uint256 public recorded;
    uint256 public paid;
    uint256 public stuck;
    uint256 public got;
    uint256 public controlDeposited;
    uint256 public controlPaid;
    uint256 public controlLeft;
    uint256 public controlGot;

    function run() external {
        cash = new Cash26292();
        locker = new OfferLocker26292(cash);
        cashC = new Cash26292();
        lockerC = new OfferLockerFixed26292(cashC);

        cash.mint(address(locker), N);
        deposited = cash.balanceOf(address(locker));
        locker.lock(1, address(this), N);
        recorded = locker.recorded();

        paid = locker.unlockOffer(1, address(this));
        stuck = cash.balanceOf(address(locker));
        got = cash.balanceOf(address(this));

        cashC.mint(address(lockerC), N);
        controlDeposited = cashC.balanceOf(address(lockerC));
        lockerC.lock(1, address(this), N);
        controlPaid = lockerC.unlockOffer(1, address(this));
        controlLeft = cashC.balanceOf(address(lockerC));
        controlGot = cashC.balanceOf(address(this));

        require(deposited == N, "deposited");
        require(recorded == N, "recorded");
        require(paid == 0, "paid");
        require(stuck == N, "stuck");
        require(got == 0, "got");
        require(controlDeposited == N, "control deposited");
        require(controlPaid == N, "control paid");
        require(controlLeft == 0, "control left");
        require(controlGot == N, "control got");
    }
}
