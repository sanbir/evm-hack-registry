// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

/*  gTrade — a canceled counter-trade increase refunds only the reduced collateral
    (Pashov, H-04, 2025-05-26).
    SYNTHETIC, cheatcode-free.
    The trader escrows 1,000 DAI. Skew says 400 DAI must be returned. The cancel
    path sends back 600 DAI and keeps the 400. The control adds the 400 back. */

contract Dai {
    mapping(address => uint256) internal _balances;
    mapping(address => mapping(address => uint256)) internal _allowance;

    function balanceOf(address account) external view returns (uint256) {
        return _balances[account];
    }

    function mint(address to, uint256 amount) external {
        _balances[to] += amount;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        _allowance[msg.sender][spender] = amount;
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        _balances[msg.sender] -= amount;
        _balances[to] += amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        _allowance[from][msg.sender] -= amount;
        _balances[from] -= amount;
        _balances[to] += amount;
        return true;
    }
}

contract IncreaseBook {
    Dai public dai;
    bool public refundCounter;
    uint256 public constant TO_RETURN = 400e18;

    constructor(Dai _dai, bool _refundCounter) {
        dai = _dai;
        refundCounter = _refundCounter;
    }

    function executeIncrease(uint256 collateralAmount) external returns (uint256 returned) {
        dai.transferFrom(msg.sender, address(this), collateralAmount);
        uint256 counterTradeCollateralToReturn = TO_RETURN;
        uint256 remaining = collateralAmount - counterTradeCollateralToReturn;
        returned = handleCanceled(msg.sender, remaining, counterTradeCollateralToReturn);
    }

    function handleCanceled(address user, uint256 collateralAmount, uint256 counterTradeCollateralToReturn)
        public
        returns (uint256 sent)
    {
        sent = collateralAmount;
        if (refundCounter) {
            sent = collateralAmount + counterTradeCollateralToReturn;
        }
        // @> VULN: sends only the reduced collateralAmount. counterTradeCollateralToReturn stays in the book.
        dai.transfer(user, sent);
    }
}

contract Exploit {
    uint256 public constant SENT = 1_000e18;
    uint256 public constant LOST = 400e18;

    Dai public dai; // nonce 1
    IncreaseBook public book; // nonce 2
    IncreaseBook public fairBook; // nonce 3

    uint256 public returnedWrong;
    uint256 public stuck;
    uint256 public returnedFair;

    constructor() {
        dai = new Dai();
        book = new IncreaseBook(dai, false);
        fairBook = new IncreaseBook(dai, true);
    }

    function run() external {
        dai.mint(address(this), SENT * 2);
        dai.approve(address(book), type(uint256).max);
        dai.approve(address(fairBook), type(uint256).max);

        returnedWrong = book.executeIncrease(SENT);
        stuck = dai.balanceOf(address(book));
        returnedFair = fairBook.executeIncrease(SENT);

        require(returnedWrong == SENT - LOST, "refunded only 600");
        require(stuck == LOST, "400 DAI stuck");
        require(returnedFair == SENT, "control did not return 1000");
        require(dai.balanceOf(address(fairBook)) == 0, "control kept funds");
    }
}
