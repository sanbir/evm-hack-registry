// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*  Rubicon — [H-15] Last borrowed asset not collateralized (Position)
    (Code4rena 2023-04-rubicon; #48954)
    SYNTHETIC, cheatcode-free reduction for the EVM Playground.
    Root cause: openPosition's _borrowLoop supplies → borrows → swaps, but the
    final loop's swapped asset remains as a free balance in the Position contract
    and is never supplied as collateral. Debt is high relative to only the
    supplied portion; a small price drop liquidates the user.
    Vulnerable end-of-loop (no final _supply) preserved with @> VULN markers. */

contract MockERC20 {
    string public name;
    string public symbol;
    uint8 public constant decimals = 18;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    constructor(string memory n, string memory s) {
        name = n;
        symbol = s;
    }

    function mint(address to, uint256 amt) external {
        totalSupply += amt;
        balanceOf[to] += amt;
    }

    function approve(address sp, uint256 amt) external returns (bool) {
        allowance[msg.sender][sp] = amt;
        return true;
    }

    function transfer(address to, uint256 amt) external returns (bool) {
        balanceOf[msg.sender] -= amt;
        balanceOf[to] += amt;
        return true;
    }

    function transferFrom(address from, address to, uint256 amt) external returns (bool) {
        uint256 a = allowance[from][msg.sender];
        if (a != type(uint256).max) allowance[from][msg.sender] = a - amt;
        balanceOf[from] -= amt;
        balanceOf[to] += amt;
        return true;
    }
}

/// @dev Quote market + simple 1:1 swap mock (asset priced 1:1 vs quote for demo).
contract BathQuote {
    MockERC20 public quote;
    MockERC20 public asset;
    uint256 public constant CF = 7e17;
    uint256 public constant WAD = 1e18;

    mapping(address => uint256) public collatAsset; // asset supplied
    mapping(address => uint256) public debtQuote; // quote borrowed

    constructor(MockERC20 a, MockERC20 q) {
        asset = a;
        quote = q;
    }

    function supplyAsset(uint256 amt) external {
        asset.transferFrom(msg.sender, address(this), amt);
        collatAsset[msg.sender] += amt;
    }

    function maxBorrowQuote(address user) public view returns (uint256) {
        uint256 maxDebt = (collatAsset[user] * CF) / WAD; // in asset units == quote units @1:1
        if (maxDebt <= debtQuote[user]) return 0;
        return maxDebt - debtQuote[user];
    }

    function borrowQuote(uint256 amt) external {
        require(amt <= maxBorrowQuote(msg.sender), "liq");
        debtQuote[msg.sender] += amt;
        quote.transfer(msg.sender, amt);
    }

    function liquidity(address user) external view returns (uint256) {
        uint256 maxDebt = (collatAsset[user] * CF) / WAD;
        if (maxDebt <= debtQuote[user]) return 0;
        return maxDebt - debtQuote[user];
    }

    /// @notice 1:1 swap quote → asset (fills from pool inventory).
    function swapQuoteForAsset(uint256 quoteAmt) external returns (uint256 assetOut) {
        quote.transferFrom(msg.sender, address(this), quoteAmt);
        assetOut = quoteAmt; // 1:1
        asset.transfer(msg.sender, assetOut);
    }
}

/// @dev Reduced Position — single-loop open leaves last asset uncollateralized.
contract Position {
    uint256 public constant WAD = 1e18;
    uint256 public constant CF = 7e17;

    BathQuote public bath;
    MockERC20 public asset;
    MockERC20 public quote;

    uint256 public supplied;
    uint256 public borrowed;
    uint256 public freeAsset; // uncollateralized leftover (the bug)

    constructor(BathQuote b, MockERC20 a, MockERC20 q) {
        bath = b;
        asset = a;
        quote = q;
    }

    function wmul(uint256 x, uint256 y) internal pure returns (uint256) {
        return (x * y) / WAD;
    }

    /// @dev _borrowLoop: supply collateral → borrow quote → swap to asset.
    function _borrowLoop(uint256 amount, uint256 toBorrowWad) internal returns (uint256) {
        // supply collateral
        asset.approve(address(bath), amount);
        bath.supplyAsset(amount);
        supplied += amount;

        // borrow fraction of max
        uint256 maxB = bath.maxBorrowQuote(address(this));
        uint256 toBorrow = wmul(maxB, toBorrowWad);
        bath.borrowQuote(toBorrow);
        borrowed += toBorrow;

        // swap borrowed quote → asset
        quote.approve(address(bath), toBorrow);
        uint256 got = bath.swapQuoteForAsset(toBorrow);
        // asset sits on Position — NOT supplied again in this loop
        return got;
    }

    /// @notice openPosition with one borrow loop (1.7x ≈ CF loop once).
    function openPosition(uint256 initMargin, uint256 /* leverage */) external {
        asset.transferFrom(msg.sender, address(this), initMargin);

        // one loop at 100% of max borrow (toBorrow = WAD)
        uint256 got = _borrowLoop(initMargin, WAD);

        // @> VULN: loop ends without supplying the swapped asset as collateral
        freeAsset = asset.balanceOf(address(this)); // @> VULN: last borrowed/swapped asset left free
        // FIX: supplied += _supply(asset, balanceOf(this));
        require(freeAsset == got, "free should equal last swap");
        // Intentionally NOT calling bath.supplyAsset(freeAsset).
    }
}

contract Exploit {
    MockERC20 public asset; // CREATE 1
    MockERC20 public quote; // CREATE 2
    BathQuote public bath; // CREATE 3
    Position public position; // CREATE 4 — vulnerable

    uint256 public constant MARGIN = 1e18;

    constructor() {
        asset = new MockERC20("WBTC", "WBTC");
        quote = new MockERC20("USDC", "USDC");
        bath = new BathQuote(asset, quote);
        position = new Position(bath, asset, quote);

        // Seed quote liquidity for borrows + asset inventory for swaps
        quote.mint(address(bath), 10e18);
        asset.mint(address(bath), 10e18);

        // User margin
        asset.mint(address(this), MARGIN);
    }

    function run() external {
        // Alice opens 1.7x-style long: supply 1, borrow 0.7 quote, swap to 0.7 asset.
        // That 0.7 asset is NOT collateralized (finding H-15).
        asset.approve(address(position), MARGIN);
        position.openPosition(MARGIN, 17e17);

        uint256 free = position.freeAsset();
        uint256 collat = bath.collatAsset(address(position));
        uint256 debt = bath.debtQuote(address(position));
        uint256 liq = bath.liquidity(address(position));

        // Harm: free asset sits uncollateralized; debt equals full CF of only supplied margin
        require(free == 7e17, "0.7e18 free asset expected");
        require(collat == MARGIN, "only margin supplied");
        require(debt == 7e17, "borrowed full CF");
        require(liq == 0, "at liquidation threshold - no buffer");
        // Total economic exposure = collat + free = 1.7, debt = 0.7, but protocol only sees collat=1
        // -> any tiny price drop liquidates despite user "owning" 1.7 asset units.
        require(asset.balanceOf(address(position)) == free, "free still on position");
    }
}
