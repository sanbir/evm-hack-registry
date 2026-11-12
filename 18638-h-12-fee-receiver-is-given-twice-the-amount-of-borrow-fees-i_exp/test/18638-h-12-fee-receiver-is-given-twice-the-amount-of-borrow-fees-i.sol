// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

/*  GMX Synthetics — H-12 (Sherlock 2023-02, issue 135)
    PositionPricingUtils.getPositionFees adds the full borrowingFeeAmount
    into totalNetCostAmount after feeReceiverAmount already includes
    borrowingFeeAmountForFeeReceiver. That slice is charged twice and paid
    to the fee receiver. The trader's deposited collateral covers it.

    Borrowing fee 1,000. Receiver factor 30%. The receiver is owed 300.
    The buggy settlement pays the receiver 600. The fair payment is 300.
    The pool still receives its 700. The control uses feeAmountForPool
    and pays the receiver 300 once.
*/

library Precision {
    uint256 internal constant FLOAT_PRECISION = 10 ** 30;

    function applyFactor(uint256 value, uint256 factor) internal pure returns (uint256) {
        return (value * factor) / FLOAT_PRECISION;
    }
}

struct ReferralFees {
    uint256 affiliateRewardAmount;
}

struct FundingFees {
    uint256 fundingFeeAmount;
}

struct PositionFees {
    ReferralFees referral;
    FundingFees funding;
    uint256 feeReceiverAmount;
    uint256 feeAmountForPool;
    uint256 positionFeeAmountForPool;
    uint256 borrowingFeeAmount;
    uint256 totalNetCostAmount;
}

contract Usd {
    string public symbol = "USD";
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

contract FeeReceiver {}

contract Pool {}

contract PricingBase {
    uint256 public constant BORROWING_FEE = 1_000e18;
    uint256 public constant RECEIVER_FACTOR = 3 * 10 ** 29;

    Usd public immutable token;
    address public trader;
    address public feeReceiver;
    address public pool;
    uint256 public collateralTokenPriceMin;
    uint256 public borrowingFeeReceiverFactorStored;

    uint256 public borrowingFeeAmount;
    uint256 public borrowingFeeAmountForFeeReceiver;
    uint256 public feeAmountForPool;
    uint256 public feeReceiverAmount;
    uint256 public totalNetCostAmount;
    uint256 public fairNetCostAmount;
    uint256 public paidToReceiver;
    uint256 public fairToReceiver;
    uint256 public paidToPool;

    constructor(Usd _token) {
        token = _token;
    }

    function getBorrowingFees() public pure returns (uint256) {
        return BORROWING_FEE;
    }

    function seed(address _trader, address _feeReceiver, address _pool) external {
        trader = _trader;
        feeReceiver = _feeReceiver;
        pool = _pool;
        collateralTokenPriceMin = 1;
        borrowingFeeReceiverFactorStored = RECEIVER_FACTOR;
        token.mint(address(this), 1_300e18);
    }

    function _pay(uint256 toReceiver, uint256 toPool) internal {
        paidToReceiver = toReceiver;
        paidToPool = toPool;
        token.transfer(feeReceiver, toReceiver);
        token.transfer(pool, toPool);
    }
}

contract Pricing is PricingBase {
    constructor(Usd _token) PricingBase(_token) {}

    function settle() external {
        PositionFees memory fees;

        fees.borrowingFeeAmount = getBorrowingFees() / collateralTokenPriceMin;
        borrowingFeeAmount = fees.borrowingFeeAmount;

        uint256 borrowingFeeReceiverFactor = borrowingFeeReceiverFactorStored;
        uint256 borrowingFeeAmountForFeeReceiver_ =
            Precision.applyFactor(fees.borrowingFeeAmount, borrowingFeeReceiverFactor);
        borrowingFeeAmountForFeeReceiver = borrowingFeeAmountForFeeReceiver_;

        fees.feeAmountForPool =
            fees.positionFeeAmountForPool + fees.borrowingFeeAmount - borrowingFeeAmountForFeeReceiver_;
        fees.feeReceiverAmount += borrowingFeeAmountForFeeReceiver_;
        feeAmountForPool = fees.feeAmountForPool;
        feeReceiverAmount = fees.feeReceiverAmount;

        fairToReceiver = borrowingFeeAmountForFeeReceiver_;
        fairNetCostAmount =
            fees.referral.affiliateRewardAmount + fees.feeReceiverAmount + fees.feeAmountForPool + fees.funding.fundingFeeAmount;

        // @> VULN: feeReceiverAmount already contains borrowingFeeAmountForFeeReceiver, and borrowingFeeAmount is added in full
        fees.totalNetCostAmount = fees.referral.affiliateRewardAmount + fees.feeReceiverAmount + fees.positionFeeAmountForPool + fees.funding.fundingFeeAmount + fees.borrowingFeeAmount;
        // FIX: fees.totalNetCostAmount = fees.referral.affiliateRewardAmount + fees.feeReceiverAmount + fees.feeAmountForPool + fees.funding.fundingFeeAmount;
        totalNetCostAmount = fees.totalNetCostAmount;

        uint256 extra = totalNetCostAmount - fairNetCostAmount;
        uint256 paid = fees.feeReceiverAmount + extra;
        _pay(paid, fees.feeAmountForPool);
    }
}

contract PricingFixed is PricingBase {
    constructor(Usd _token) PricingBase(_token) {}

    function settle() external {
        PositionFees memory fees;

        fees.borrowingFeeAmount = getBorrowingFees() / collateralTokenPriceMin;
        borrowingFeeAmount = fees.borrowingFeeAmount;

        uint256 borrowingFeeReceiverFactor = borrowingFeeReceiverFactorStored;
        uint256 borrowingFeeAmountForFeeReceiver_ =
            Precision.applyFactor(fees.borrowingFeeAmount, borrowingFeeReceiverFactor);
        borrowingFeeAmountForFeeReceiver = borrowingFeeAmountForFeeReceiver_;

        fees.feeAmountForPool =
            fees.positionFeeAmountForPool + fees.borrowingFeeAmount - borrowingFeeAmountForFeeReceiver_;
        fees.feeReceiverAmount += borrowingFeeAmountForFeeReceiver_;
        feeAmountForPool = fees.feeAmountForPool;
        feeReceiverAmount = fees.feeReceiverAmount;

        fairToReceiver = borrowingFeeAmountForFeeReceiver_;
        fairNetCostAmount =
            fees.referral.affiliateRewardAmount + fees.feeReceiverAmount + fees.feeAmountForPool + fees.funding.fundingFeeAmount;

        fees.totalNetCostAmount = fees.referral.affiliateRewardAmount + fees.feeReceiverAmount + fees.feeAmountForPool
            + fees.funding.fundingFeeAmount;
        totalNetCostAmount = fees.totalNetCostAmount;

        _pay(fees.feeReceiverAmount, fees.feeAmountForPool);
    }
}

contract Exploit {
    Usd public token;
    Pricing public pricing;
    FeeReceiver public receiver;
    Pool public pool;

    constructor() {
        token = new Usd();
        pricing = new Pricing(token);
        receiver = new FeeReceiver();
        pool = new Pool();
    }

    function run() external {
        pricing.seed(msg.sender, address(receiver), address(pool));
        uint256 slice = Precision.applyFactor(pricing.BORROWING_FEE(), pricing.RECEIVER_FACTOR());
        require(slice == 300e18, "slice");
        pricing.settle();
        require(pricing.paidToReceiver() == 600e18, "paid");
        require(pricing.fairToReceiver() == 300e18, "fair");
        require(pricing.paidToReceiver() == 2 * pricing.fairToReceiver(), "twice");
        require(token.balanceOf(address(receiver)) == 600e18, "receiver");
        require(pricing.totalNetCostAmount() == 1_300e18, "charged");
        require(pricing.fairNetCostAmount() == 1_000e18, "fair cost");
        require(token.balanceOf(address(pool)) == 700e18, "pool");
        require(token.balanceOf(address(pricing)) == 0, "deposit consumed");
    }
}
