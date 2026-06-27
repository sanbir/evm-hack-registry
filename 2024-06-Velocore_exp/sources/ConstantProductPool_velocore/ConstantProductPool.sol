// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import "openzeppelin-contracts/contracts/utils/math/Math.sol";
import "openzeppelin-contracts/contracts/utils/math/SafeCast.sol";
import {SD59x18, sd, exp2, log2, convert, pow} from "lib/prb-math/src/SD59x18.sol";
import "src/lib/Token.sol";
import "src/lib/UncheckedMemory.sol";
import "src/lib/PoolBalanceLib.sol";
import {rpow} from "src/lib/RPow.sol";
import "src/pools/SingleTokenGauge.sol";
import "./ConstantProductLibrary.sol";

/**
 * @dev a pool with weighted geometric average as its invariant, aka Balancer weighted pool.
 * Please refer to the url below for detailed mathematical explanation.
 * https://velocore.gitbook.io/velocore-v2/technical-docs/pool-specifics/generalized-cpmm
 *
 * There is two implementation of the same mathematical function. one in this contract, and another in ConstantProductLibrary.
 * they were separated to make compiled bytecode less than 24kb.
 *
 * one implementation uses integer division; they are cheap and accurate, but prone to overflows, especially when weights are high.
 * one implementation uses addition and substraction over logarithm; they are expensive and inaccurate, but can handle far more ranges.
 *
 * this contract is the first one. it falls back to the second one (ConstantProductLibrary) when neccesary.
 *
 */

function ceilDivUnsafe(uint256 a, uint256 b) pure returns (uint256) {
    // (a + b - 1) / b
    unchecked {
        return (a + b - 1) / b;
    }
}

contract ConstantProductPool is SingleTokenGauge, PoolWithLPToken, ISwap, IBribe {
    using UncheckedMemory for uint256[];
    using UncheckedMemory for int128[];
    using UncheckedMemory for Token[];
    using SafeCast for int256;
    using SafeCast for uint256;
    using TokenLib for Token;

    event FeeChanged(uint256 fee1e18);
    event DecayChanged(uint256 decay);

    uint256 private constant _MAX_TOKENS = 4;

    uint256 private immutable _totalTokens;

    Token internal immutable _token0;
    Token internal immutable _token1;
    Token internal immutable _token2;
    Token internal immutable _token3;

    uint256 internal immutable _sumWeight;
    uint256 internal immutable _weight0;
    uint256 internal immutable _weight1;
    uint256 internal immutable _weight2;
    uint256 internal immutable _weight3;
    ConstantProductLibrary immutable lib;

    uint32 public decayRate;
    uint32 public fee1e9;
    uint32 public lastWithdrawTimestamp;
    uint128 public feeMultiplier;
    uint8 internal immutable _lpDecimals;

    function setParam(uint256 fee1e9_, uint256 decayRate_) external authenticate {
        require(fee1e9 <= 0.1e9);
        fee1e9 = uint32(fee1e9_);
        decayRate = uint32(decayRate_);

        emit FeeChanged(fee1e9 * uint256(1e8));
        emit DecayChanged(decayRate);
    }

    constructor(
        ConstantProductLibrary lib_,
        IVault vault_,
        string memory _name,
        string memory _symbol,
        Token[] memory tokens,
        uint256[] memory weights,
        uint32 fee1e9_,
        uint32 decay
    ) SingleTokenGauge(vault_, toToken(this), this) {
        require(tokens.length >= 2);
        decayRate = decay;
        lib = lib_;
        fee1e9 = fee1e9_;
        uint256 numTokens = tokens.length;
        _totalTokens = numTokens;
        uint256 sumDecimals;
        uint256 sumWeight = 0;
        unchecked {
            for (uint8 i = 0; i < numTokens; i++) {
                sumWeight = sumWeight + weights.u(i);
                sumDecimals += weights.u(i) * tokens.u(i).decimals();
            }
            /**
             * lp decimal is set to the weighted arithmetic average of underlying token's decimals.
             * This makes LP amount to have similar order of magnitude to the underlying tokens.
             */
            _lpDecimals = uint8(sumDecimals / sumWeight);

            _token0 = tokens.u(0);
            _token1 = tokens.u(1);
            _token2 = numTokens > 2 ? tokens.u(2) : Token.wrap(bytes32(0));
            _token3 = numTokens > 3 ? tokens.u(3) : Token.wrap(bytes32(0));

            _sumWeight = sumWeight;
            _weight0 = weights.u(0);
            _weight1 = weights.u(1);
            _weight2 = numTokens > 2 ? weights.u(2) : 0;
            _weight3 = numTokens > 3 ? weights.u(3) : 0;
        }
        PoolWithLPToken._initialize(_name, _symbol);
        emit FeeChanged(fee1e9 * uint256(1e8));
    }

    function _tokenWeight(Token token) internal view returns (uint256) {
        if (token == _token0) return (_weight0);
        else if (token == _token1) return (_weight1);
        else if (token == _token2) return (_weight2);
        else if (token == _token3) return (_weight3);
        else revert();
    }

    // a fallback swap
    // computes the same function over log space.
    // consumes more gas but produces more accurate result on transactions that are relatively large compared to the pool (e.g. depositing on empty pool)

    function _return_logarithmic_swap() internal {
        address lib_ = address(lib);
        assembly ("memory-safe") {
            calldatacopy(mload(0x40), 0, calldatasize())
            let success := call(gas(), lib_, 0, mload(0x40), calldatasize(), 0, 0)
            returndatacopy(mload(0x40), 0, returndatasize())
            if success { return(mload(0x40), returndatasize()) }
            revert(mload(0x40), returndatasize())
        }
    }

    function notifyWithdraw(uint128 m) external {
        require(msg.sender == address(lib));
        feeMultiplier = m;
        lastWithdrawTimestamp = uint32(block.timestamp);
    }

    function notifyMint(uint128 m) external {
        require(msg.sender == address(lib));
        _simulateMint(uint256(m));
    }

    function notifyBurn(uint128 m) external {
        require(msg.sender == address(lib));
        _simulateBurn(uint256(m));
    }
    // positive amount => pool receives, user gives
    // negative amount => user receives, pool gives
    // type(int256).max => to be computed

    function velocore__execute(address, Token[] calldata tokens, int128[] memory r, bytes calldata data)
        external
        returns (int128[] memory, int128[] memory)
    {
        if (data.length > 0) {
            _return_logarithmic_swap();
        }
        uint256 effectiveFee1e9 = fee1e9;
        if (lastWithdrawTimestamp == block.timestamp) {
            unchecked {
                effectiveFee1e9 = effectiveFee1e9 * feeMultiplier / 1e9;
            }
        }

        uint256 iLp = type(uint256).max;
        uint256[] memory a = _getPoolBalances(tokens);
        uint256[] memory weights = new uint256[](tokens.length);
        unchecked {
            for (uint256 i = 0; i < tokens.length; ++i) {
                Token token = tokens.uc(i);
                if (token == toToken(this)) {
                    weights.u(i, _sumWeight);
                    iLp = i;
                } else {
                    weights.u(i, _tokenWeight(tokens.uc(i)));
                    a.u(i, a.u(i) + 1);
                }
            }
        }
        uint256 invariantMin;
        uint256 invariantMax;
        uint256 k = 1e18;
        bool lpInvolved = iLp != type(uint256).max;
        bool lpUnknown = lpInvolved && (r.u(iLp) == type(int128).max);
        unchecked {
            if (lpInvolved) {
                (, invariantMin, invariantMax) = _invariant();
                if (lpUnknown) {
                    // instead of calculating the true value of k, which is a weighted geometric average, we approximate with an arithmetic average.
                    // this approximation results in higher k which means lower fee, but k otherwise doesn't matter.
                    uint256 kw = 0;
                    for (uint256 i = 0; i < tokens.length; ++i) {
                        if (r.u(i) == type(int128).max) {
                            if (i != iLp) {
                                kw += weights.u(i);
                            }
                            continue;
                        }
                        uint256 balanceRatio;
                        balanceRatio = ((int256(a.u(i)) + r.u(i)).toUint256() * 1e18) / a.u(i);
                        k += weights.u(i) * balanceRatio;
                    }
                    k /= (_sumWeight - kw);
                } else {
                    k = (1e18 * (int256(invariantMax) - r.u(iLp)).toUint256()) / invariantMax;
                }
            }
        }
        uint256 requestedGrowth1e18 = 1e18;
        uint256 sumUnknownWeight = 0;
        uint256 sumKnownWeight = 0;
        for (uint256 i = 0; i < tokens.length; i++) {
            if (r.u(i) == type(int128).max) {
                // unknowns
                unchecked {
                    if (i != iLp) sumUnknownWeight += weights.u(i);
                }
            } else {
                uint256 tokenGrowth1e18;
                if (i == iLp) {
                    unchecked {
                        uint256 newInvariant = (int256(invariantMax) - r.u(iLp)).toUint256();
                        tokenGrowth1e18 = uint256((1e18 * invariantMin) / newInvariant);
                    }
                } else {
                    unchecked {
                        sumKnownWeight += weights.u(i);
                        uint256 b = (int256(a.u(i)) + r.u(i)).toUint256(); // this captures overflow too
                        uint256 fee;
                        uint256 a_prime = k > 1e18 ? a.u(i) : (k * a.u(i)) / 1e18;
                        uint256 b_prime = k > 1e18 ? (b * 1e18 / k) : b; // fees are not crucial for the integrity of the pool. avoiding ceilDiv to save gas

                        if (b_prime > a_prime) {
                            fee = ceilDivUnsafe((b_prime - a_prime) * effectiveFee1e9, 1e9);
                        }

                        tokenGrowth1e18 = (1e18 * (b - fee)) / a.u(i);
                    }
                }
                if (tokenGrowth1e18 <= 0.01e18 || tokenGrowth1e18 >= 100e18) {
                    _return_logarithmic_swap();
                }
                requestedGrowth1e18 = (requestedGrowth1e18 * rpow(uint256(tokenGrowth1e18), weights.u(i), 1e18)) / 1e18; // less growth == less exit, so round down
                require(tokenGrowth1e18 > 0);
            }
        }

        unchecked {
            uint256 unaccountedFeeAsGrowth1e18 = k >= 1e18
                ? 1e18
                : rpow(1e18 - ((1e18 - k) * effectiveFee1e9) / 1e9, _sumWeight - sumUnknownWeight - sumKnownWeight, 1e18);
            requestedGrowth1e18 = (requestedGrowth1e18 * unaccountedFeeAsGrowth1e18) / 1e18;
        }

        uint256 g_;
        uint256 g;

        {
            int256 w = int256(sumUnknownWeight);
            unchecked {
                if (lpUnknown) w -= int256(_sumWeight);
            }

            require(w != 0);

            (g_, g) = pow_reciprocal(requestedGrowth1e18, -w);
        }
        for (uint256 i = 0; i < tokens.length; i++) {
            if (r.u(i) != type(int128).max) continue;

            if (i != iLp) {
                uint256 b = Math.ceilDiv(g * a.u(i), 1e18);
                uint256 fee;
                uint256 a_prime = k > 1e18 ? a.u(i) : (k * a.u(i)) / 1e18;
                uint256 b_prime = k > 1e18 ? Math.ceilDiv(uint256(b * 1e18), k) : b;

                if (b_prime > a_prime) {
                    unchecked {
                        fee = Math.ceilDiv((b_prime - a_prime) * 1e9, 1e9 - effectiveFee1e9) - (b_prime - a_prime);
                    }
                }
                r.u(i, ((b + fee).toInt256() - a.u(i).toInt256()).toInt128());
            } else {
                uint256 b = (g_ * invariantMin) / 1e18;
                r.u(i, -(b.toInt256() - invariantMax.toInt256()).toInt128());
            }
        }

        if (iLp != type(uint256).max && r.u(iLp) > 0) {
            _simulateBurn(uint256(int256(r.u(iLp))));
            if (lastWithdrawTimestamp != block.timestamp) {
                feeMultiplier = 1e9;
                lastWithdrawTimestamp = uint32(block.timestamp);
            }
            feeMultiplier = (feeMultiplier * invariantMax / (invariantMax - uint256(int256(r.u(iLp))))).toUint128();
        } else if (iLp != type(uint256).max && r.u(iLp) < 0) {
            _simulateMint(uint256(int256(-r.u(iLp))));
        }
        return (new int128[](tokens.length), r);
    }

    // x^(1/n)
    function pow_reciprocal(uint256 x1e18, int256 n) internal pure returns (uint256, uint256) {
        if (n == 0 || x1e18 == 1e18) return (1e18, 1e18);
        if (n == 1) return (x1e18, x1e18);
        if (n == -1) {
            unchecked {
                return ((1e18 * 1e18) / x1e18, ceilDivUnsafe(1e18 * 1e18, x1e18));
            }
        }
        if (n == 2) {
            uint256 s = Math.sqrt(1e18 * x1e18);
            unchecked {
                if (s * s < x1e18 * 1e18) {
                    return (s, s + 1);
                }
                return (s, s);
            }
        }
        if (n == -2) {
            uint256 s = Math.sqrt(1e18 * x1e18);
            unchecked {
                uint256 ss = (s * s < x1e18 * 1e18) ? s + 1 : s;

                return ((1e18 * 1e18) / ss, Math.ceilDiv(1e18 * 1e18, s));
            }
        }

        uint256 raw = uint256((pow(sd(x1e18.toInt256()), sd(1e18) / convert(n))).intoInt256());

        uint256 maxError = Math.ceilDiv(raw * 10000, 1e18) + 1;
        return (raw >= maxError ? raw - maxError : 0, raw + maxError);
    }

    function poolBalances() public view returns (uint256[] memory) {
        return _getPoolBalances(relevantTokens());
    }

    function relevantTokens() public view virtual returns (Token[] memory) {
        Token[] memory ret = new Token[](_totalTokens + 1);
        unchecked {
            ret.u(0, toToken(this));
            ret.u(1, _token0);
            ret.u(2, _token1);
            if (_totalTokens > 2) ret.u(3, _token2);
            if (_totalTokens > 3) ret.u(4, _token3);
        }
        return ret;
    }

    function tokenWeights() public view virtual returns (uint256[] memory) {
        uint256[] memory ret = new uint256[](_totalTokens + 1);
        unchecked {
            ret.u(0, _sumWeight);
            ret.u(1, _weight0);
            ret.u(2, _weight1);
            if (_totalTokens > 2) ret.u(3, _weight2);
            if (_totalTokens > 3) ret.u(4, _weight3);
        }
        return ret;
    }

    function _invariant() internal view virtual returns (uint256, uint256, uint256) {
        uint256[] memory balances = _getPoolBalances(relevantTokens());
        unchecked {
            if (_totalTokens == 2 && _weight0 == _weight1) {
                uint256 inv = Math.sqrt((balances.u(1) + 1) * (balances.u(2) + 1));
                return (balances.u(0), inv, inv * inv < (balances.u(1) + 1) * (balances.u(2) + 1) ? inv + 1 : inv);
            }
        }
        uint256[] memory weights = tokenWeights();
        SD59x18 logInvariant = sd(0);
        unchecked {
            for (uint256 i = 1; i < weights.length; i++) {
                SD59x18 g = log2(convert(int256(balances.u(i) + 1)));
                logInvariant = logInvariant + (g * convert(int256(weights.u(i))));
            }
            logInvariant = logInvariant / convert(int256(_sumWeight));
        }
        uint256 invariant = convert(exp2(logInvariant)).toUint256();

        return (0, invariant, Math.ceilDiv(invariant * (1e18 + 1e5), 1e18) + 1);
    }

    function _excessInvariant() internal view virtual returns (uint256) {
        uint256 minted = totalSupply();
        (, uint256 actual,) = _invariant();
        return actual < minted ? 0 : actual - minted;
    }

    function listedTokens() public view override returns (Token[] memory) {
        Token[] memory ret = new Token[](_totalTokens);
        unchecked {
            ret.u(0, _token0);
            ret.u(1, _token1);
            if (_totalTokens > 2) ret.u(2, _token2);
            if (_totalTokens > 3) ret.u(3, _token3);
        }
        return ret;
    }

    function swapType() external view override returns (string memory) {
        return "cpmm";
    }

    function lpTokens() public view override returns (Token[] memory ret) {
        ret = new Token[](1);
        ret[0] = toToken(this);
    }

    function poolParams() external view override(IPool, Pool) returns (bytes memory) {
        return abi.encode(fee1e9 * uint256(1e9), tokenWeights());
    }

    function decimals() external view override returns (uint8) {
        return _lpDecimals;
    }

    function velocore__bribe(IGauge gauge, uint256 elapsed)
        external
        onlyVault
        returns (
            Token[] memory bribeTokens,
            int128[] memory deltaGauge,
            int128[] memory deltaPool,
            int128[] memory deltaExternal
        )
    {
        require(address(gauge) == address(this));
        uint256 decay = 2 ** 32 - rpow(decayRate, elapsed, 2 ** 32);
        uint256 decayed = _excessInvariant() * decay / 2 ** 32;

        bribeTokens = new Token[](1);
        bribeTokens[0] = toToken(this);
        deltaGauge = new int128[](1);
        deltaPool = new int128[](1);
        deltaExternal = new int128[](1);

        deltaPool.u(0, -decayed.toInt256().toInt128());
    }

    function bribeTokens(IGauge gauge) external view returns (Token[] memory) {
        Token v = toToken(this);
        assembly {
            mstore(0, 0x20)
            mstore(0x20, 1)
            mstore(0x40, v)
            return(0, 0x60)
        }
    }

    function bribeRates(IGauge gauge) external view returns (uint256[] memory) {
        uint256 v;
        unchecked {
            v = address(gauge) == address(this) ? _excessInvariant() * (2 ** 32 - uint256(decayRate)) / 2 ** 32 : 0;
        }
        assembly {
            mstore(0, 0x20)
            mstore(0x20, 1)
            mstore(0x40, v)
            return(0, 0x60)
        }
    }

    function underlyingTokens(Token tok) external view returns (Token[] memory) {
        require(tok == toToken(this));
        return listedTokens();
    }

    function setFeeToZero() external onlyVault {
        feeMultiplier = 0;
        fee1e9 = 0;
    }
}
