// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

/*  Index Fun MarketController — Sherlock 2025-10, issue 60
    _executeTokenSwap subtracts the buyer's trade fee from paymentAmount
    before paying the seller. JIT minting charges that fee on top.

    1,000 YES tokens at price 6,000 / 10,000 is a 600 payment.
    The default fee is 100 bps, so the fee is 6. The seller receives 594.
    The buyer pays 600, not 606. The seller paid the buyer's fee.
*/

contract Cash {
    string public symbol = "USDC";
    uint8 public constant decimals = 18;
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

contract Treasury {}

contract Seller {}

contract MarketController {
    uint256 public constant FEE_DENOMINATOR = 10_000;
    uint256 public tradeFeeRate = 100;

    Cash public immutable cash;
    address public treasury;
    address public seller;
    uint256 public paymentAmount;
    uint256 public tradeFee;
    uint256 public netPayment;
    uint256 public fairSeller;
    uint256 public fairBuyerCost;

    constructor(Cash _cash) {
        cash = _cash;
    }

    function configure(address _treasury, address _seller) external {
        treasury = _treasury;
        seller = _seller;
    }

    function _executeTokenSwap(address buyer, uint256 fillAmount, uint256 price) external {
        paymentAmount = (fillAmount * price) / FEE_DENOMINATOR;
        uint256 buyerFeeRate = tradeFeeRate;
        tradeFee = (paymentAmount * buyerFeeRate) / FEE_DENOMINATOR;
        // @> VULN: the buyer's trade fee is deducted from the seller's proceeds instead of charged on top
        uint256 net = paymentAmount - tradeFee;
        netPayment = net;
        fairSeller = paymentAmount;
        fairBuyerCost = paymentAmount + tradeFee;
        cash.transfer(treasury, tradeFee);
        cash.transfer(seller, net);
        buyer;
    }
}

contract MarketControllerFixed {
    uint256 public constant FEE_DENOMINATOR = 10_000;
    uint256 public tradeFeeRate = 100;
    Cash public immutable cash;
    address public treasury;
    address public seller;
    uint256 public netPayment;
    uint256 public tradeFee;

    constructor(Cash _cash) {
        cash = _cash;
    }

    function configure(address _treasury, address _seller) external {
        treasury = _treasury;
        seller = _seller;
    }

    function _executeTokenSwap(address buyer, uint256 fillAmount, uint256 price) external {
        uint256 paymentAmount = (fillAmount * price) / FEE_DENOMINATOR;
        tradeFee = (paymentAmount * tradeFeeRate) / FEE_DENOMINATOR;
        netPayment = paymentAmount;
        cash.transfer(seller, paymentAmount);
        cash.transfer(treasury, tradeFee);
        buyer;
    }
}

contract Exploit {
    Cash public cash;
    Treasury public treasury;
    Seller public seller;
    MarketController public market;

    constructor() {
        cash = new Cash();
        treasury = new Treasury();
        seller = new Seller();
        market = new MarketController(cash);
    }

    function run() external {
        market.configure(address(treasury), address(seller));
        cash.mint(address(market), 606 ether);
        market._executeTokenSwap(msg.sender, 1_000 ether, 6_000);
        require(market.paymentAmount() == 600 ether, "payment");
        require(market.tradeFee() == 6 ether, "fee");
        require(market.netPayment() == 594 ether, "net");
        require(market.fairSeller() == 600 ether, "fair seller");
        require(market.fairBuyerCost() == 606 ether, "fair buyer");
        require(cash.balanceOf(address(seller)) == 594 ether, "seller got 594");
        require(cash.balanceOf(address(treasury)) == 6 ether, "treasury 6");
        require(cash.balanceOf(address(market)) == 6 ether, "buyer kept 6");
        require(600 ether - cash.balanceOf(address(seller)) == 6 ether, "seller short 6");
    }
}
