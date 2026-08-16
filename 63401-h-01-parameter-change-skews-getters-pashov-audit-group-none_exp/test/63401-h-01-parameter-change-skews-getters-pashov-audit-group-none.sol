// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

// ─────────────────────────────────────────────────────────────────────────────
// Synthetic, self-contained reproduction of RegnumAurum finding 63401 (H-01):
// "Parameter change skews getters".
//
// Report: pashov/audits RegnumAurum-security-review_2025-08-12 (H-01).
// Contract: ReserveLogic (updateState + getLiquidityIndex / getNormalizedIncome).
//
// Root cause: interest accrual for the elapsed period is booked by updateState()
// using the CACHED rate `rateData.currentLiquidityRate` (the last-calculated
// value). But the view getter getLiquidityIndex() (backing getNormalizedIncome)
// RE-CALCULATES the liquidity rate on the fly via
//   calculateLiquidityRate(currentUtilizationRate, currentUsageRate, protocolFeeRate, totalUsage)
// using the CURRENT `protocolFeeRate`. If the protocol changes protocolFeeRate
// after the last state update, the getter attributes the whole elapsed timeDelta
// to a rate that was never actually applied — so getNormalizedIncome returns a
// value that diverges from the index the protocol will actually book on the next
// real updateState(). Because getNormalizedIncome / getNormalizedDebt are read at
// many points in the codebase, every consumer sees a skewed balance.
// (The finding notes the same happens for getNormalizedDebt on other rate params;
//  the verbatim snippet marked in the report is the income getter, reproduced here.)
//
// The two verbatim blocks from the finding (the updateState reserve-update block
// and the getLiquidityIndex getter) are reproduced byte-for-byte. The math
// helpers calculateLiquidityIndex / calculateUsageIndex / calculateLiquidityRate
// are faithful Aave-style RAY-math doubles (linear income index, compounded debt
// index, borrow-rate * utilization * (1 - reserveFactor)) — the skew emerges from
// the verbatim code, it is never asserted by a fake constant.
// ─────────────────────────────────────────────────────────────────────────────

/// @dev Minimal ERC20 double used only to record the accounting-error magnitude.
contract MiniToken {
    string public name;
    string public symbol;
    uint8 public constant decimals = 18;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;

    constructor(string memory _name, string memory _symbol) {
        name = _name;
        symbol = _symbol;
    }

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply += amount;
    }
}

struct ReserveData {
    uint256 liquidityIndex;
    uint256 usageIndex;
    uint40 lastUpdateTimestamp;
    uint256 totalUsage;
}

struct ReserveRateData {
    uint256 currentLiquidityRate; // cached rate booked by updateState
    uint256 currentUsageRate;
    uint256 currentUtilizationRate;
    uint256 protocolFeeRate; // the parameter that can change under the getter
}

// ─────────────────────────────────────────────────────────────────────────────
// VULNERABLE contract — ReserveLogic. The updateState reserve-update block and
// the getLiquidityIndex getter are reproduced VERBATIM from the finding.
// ─────────────────────────────────────────────────────────────────────────────
contract ReserveModule {
    // Playground-robust clock: the browser EVM has no vm.warp, so time is driven
    // by a settable mock (the verbatim interest formula below is unchanged).
    uint256 public mockNow;
    function setNow(uint256 t) external { mockNow = t; }

    uint256 internal constant RAY = 1e27;
    uint256 internal constant SECONDS_PER_YEAR = 365 days;

    ReserveData internal _reserve;
    ReserveRateData internal _rateData;

    constructor(
        uint256 liquidityIndex_,
        uint256 usageIndex_,
        uint256 utilizationRate_,
        uint256 usageRate_,
        uint256 protocolFeeRate_,
        uint256 totalUsage_
    ) {
        _reserve.liquidityIndex = liquidityIndex_;
        _reserve.usageIndex = usageIndex_;
        _reserve.lastUpdateTimestamp = 0; // reserve last touched at t0
        _reserve.totalUsage = totalUsage_;

        _rateData.currentUtilizationRate = utilizationRate_;
        _rateData.currentUsageRate = usageRate_;
        _rateData.protocolFeeRate = protocolFeeRate_;
        // cache the liquidity rate exactly as it was last calculated (with the
        // fee in force at the last update) — faithfully derived, not a constant.
        _rateData.currentLiquidityRate =
            calculateLiquidityRate(utilizationRate_, usageRate_, protocolFeeRate_, totalUsage_);
    }

    // ── faithful RAY-math helpers (bodies not shown in the finding) ──

    /// @dev linear interest applied to the income (liquidity) index.
    function calculateLiquidityIndex(uint256 rate, uint256 timeDelta, uint256 oldIndex)
        internal
        pure
        returns (uint256)
    {
        uint256 linearInterest = (rate * timeDelta) / SECONDS_PER_YEAR + RAY;
        return (linearInterest * oldIndex) / RAY;
    }

    /// @dev compounded interest (Aave binomial, 2nd order) applied to the debt index.
    function calculateUsageIndex(uint256 rate, uint256 timeDelta, uint256 oldIndex)
        internal
        pure
        returns (uint256)
    {
        if (timeDelta == 0) return oldIndex;
        uint256 ratePerSecond = rate / SECONDS_PER_YEAR;
        uint256 expMinusOne = timeDelta;
        uint256 expMinusTwo = timeDelta > 1 ? timeDelta - 1 : 0;
        uint256 basePowerTwo = (ratePerSecond * ratePerSecond) / RAY;
        uint256 secondTerm = (expMinusOne * expMinusTwo * basePowerTwo) / 2;
        uint256 compounded = RAY + ratePerSecond * expMinusOne + secondTerm;
        return (compounded * oldIndex) / RAY;
    }

    /// @dev liquidity (income) rate = borrow rate * utilization * (1 - reserveFactor).
    ///      protocolFeeRate is the reserve factor: raising it lowers depositor income.
    function calculateLiquidityRate(
        uint256 utilizationRate,
        uint256 usageRate,
        uint256 protocolFeeRate,
        uint256 /* totalUsage */
    ) internal pure returns (uint256) {
        uint256 grossRate = (usageRate * utilizationRate) / RAY;
        return (grossRate * (RAY - protocolFeeRate)) / RAY;
    }

    // ── admin parameter change (setProtocolFeeRate) ──
    function setProtocolFeeRate(uint256 newProtocolFeeRate) external {
        _rateData.protocolFeeRate = newProtocolFeeRate;
    }

    // ── updateState: books the elapsed accrual using the CACHED rate ──
    function updateState() external {
        _updateState(_reserve, _rateData);
    }

    function _updateState(ReserveData storage reserve, ReserveRateData storage rateData) internal {
        uint256 timeDelta = mockNow - uint256(reserve.lastUpdateTimestamp);
        if (timeDelta < 1) return;

        // Reserve update

        reserve.liquidityIndex = calculateLiquidityIndex(
            rateData.currentLiquidityRate,
            timeDelta,
            reserve.liquidityIndex
        );

        // Update usage index (debt index) using compounded interest
        reserve.usageIndex = calculateUsageIndex(
            rateData.currentUsageRate,
            timeDelta,
            reserve.usageIndex
        );

        reserve.lastUpdateTimestamp = uint40(mockNow);
    }

    // ── the vulnerable getter (verbatim), and its public consumer ──
    function getLiquidityIndex(ReserveData storage reserve, ReserveRateData storage rateData) internal view returns (uint256) {
        uint256 timeDelta = mockNow - uint256(reserve.lastUpdateTimestamp);
        if(timeDelta < 1) {
            return reserve.liquidityIndex;
        }

        return calculateLiquidityIndex(
            calculateLiquidityRate(rateData.currentUtilizationRate, rateData.currentUsageRate, rateData.protocolFeeRate, reserve.totalUsage), // @> VULN: recomputes the rate with the CURRENT protocolFeeRate instead of the cached currentLiquidityRate, so a fee change skews the value returned to every getNormalizedIncome consumer
            timeDelta,
            reserve.liquidityIndex
        );
    }

    /// @notice used at many points in the codebase (skewed by the bug).
    function getNormalizedIncome() external view returns (uint256) {
        return getLiquidityIndex(_reserve, _rateData);
    }

    function reserveLiquidityIndex() external view returns (uint256) {
        return _reserve.liquidityIndex;
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Exploit driver: a reserve is consistent at the last update (fee = 10%). One
// year elapses. The protocol raises protocolFeeRate 10% -> 30%. getNormalizedIncome
// now returns a lower income index than the value updateState actually books from
// the cached rate — a depositor's reported balance is understated. The gap is
// recorded on a SKEW-income marker minted to the SINK.
// ─────────────────────────────────────────────────────────────────────────────
contract Exploit {
    address internal constant SINK = 0x000000000000000000000000000000000000D00d;

    uint256 internal constant RAY = 1e27;
    uint256 internal constant IDX0 = 1e27;      // starting liquidity/usage index (RAY)
    uint256 internal constant UTIL = 8e26;      // 0.8 utilization
    uint256 internal constant USAGE = 1e26;     // 0.1 (10%) borrow/usage rate
    uint256 internal constant FEE0 = 1e26;      // 0.1 (10%) protocol fee at last update
    uint256 internal constant FEE1 = 3e26;      // 0.3 (30%) protocol fee after the change
    uint256 internal constant TOTAL_USAGE = 500 ether;
    uint256 internal constant SCALED_BALANCE = 1000 ether; // a depositor's scaled balance

    ReserveModule public vuln;
    MiniToken public marker;

    uint256 public incomeBeforeChange; // getter with fee 10% (consistent)
    uint256 public incomeAfterChange;  // getter with fee 30% (SKEWED)
    uint256 public bookedIndex;        // index updateState actually books (cached rate)
    uint256 public reportedBalance;    // depositor balance via skewed getter
    uint256 public bookedBalance;      // depositor balance via booked index
    uint256 public accountingError;    // the harm magnitude
    uint256 public sinkMarkerBalance;
    address public vulnAddr;
    address public markerAddr;

    function run() external {
        // Deterministic deploy order (children of this Exploit):
        vuln = new ReserveModule(IDX0, IDX0, UTIL, USAGE, FEE0, TOTAL_USAGE); // nonce 1 (VULN)
        marker = new MiniToken("SKEW-income", "SKEW");                        // nonce 2 (marker)
        vulnAddr = address(vuln);
        markerAddr = address(marker);

        // requires block.timestamp >= 1y so timeDelta = 1 year (lastUpdate = 0).
        vuln.setNow(365 days); // drive the mock clock to 1 year elapsed

        // getter BEFORE the parameter change: fee still 10%, so the recomputed
        // rate equals the cached rate -> matches what updateState will book.
        incomeBeforeChange = vuln.getNormalizedIncome();

        // protocol raises the reserve/protocol fee (a parameter change).
        vuln.setProtocolFeeRate(FEE1);

        // getter AFTER the change: recomputes with the NEW 30% fee -> skewed.
        incomeAfterChange = vuln.getNormalizedIncome();

        // updateState books the elapsed year using the CACHED (10%-fee) rate.
        vuln.updateState();
        bookedIndex = vuln.reserveLiquidityIndex();

        // Before the change the getter matched the value the protocol books:
        require(incomeBeforeChange == bookedIndex, "getter should match booked value before change");
        // After the change the getter diverges from the booked value:
        require(incomeAfterChange != bookedIndex, "getter not skewed by parameter change");
        // Fee up -> depositor income under-reported by the getter:
        require(bookedIndex > incomeAfterChange, "unexpected skew direction");

        // Concrete consequence: a depositor reading getNormalizedIncome sees a
        // smaller balance than the protocol actually accrues for them.
        reportedBalance = SCALED_BALANCE * incomeAfterChange / RAY;
        bookedBalance = SCALED_BALANCE * bookedIndex / RAY;
        accountingError = bookedBalance - reportedBalance;

        // fee 10%->30% over 1y: booked idx 1.072e27, getter idx 1.056e27,
        // depositor balance 1072 vs 1056 -> 16 tokens understated.
        require(accountingError == 16 ether, "accounting error magnitude mismatch");

        marker.mint(SINK, accountingError);
        sinkMarkerBalance = marker.balanceOf(SINK);
    }
}
