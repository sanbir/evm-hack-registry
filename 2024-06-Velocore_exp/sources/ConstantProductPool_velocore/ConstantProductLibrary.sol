// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import "openzeppelin-contracts/contracts/utils/math/Math.sol";
import "openzeppelin-contracts/contracts/utils/math/SafeCast.sol";
import {SD59x18, sd, exp2, log2, convert, pow, intoInt256} from "lib/prb-math/src/SD59x18.sol";
import "src/lib/Token.sol";
import "src/lib/UncheckedMemory.sol";
import "./ConstantProductPool.sol";

// a contract for performing fallback swap
// completely avoids integer division.
// consumes more gas but produces more accurate result on transactions that are relatively large compared to the pool (e.g. depositing on empty pool)

// separated to make the contract < 24kb

contract ConstantProductLibrary {
    using UncheckedMemory for uint256[];
    using UncheckedMemory for int128[];
    using UncheckedMemory for Token[];
    using SafeCast for int256;
    using SafeCast for uint256;
    using TokenLib for Token;

    function velocore__execute(address, Token[] calldata tokens, int128[] memory r_, bytes calldata)
        external
        returns (int128[] memory, int128[] memory)
    {
        ConstantProductPool caller = ConstantProductPool(msg.sender);
        Token[] memory t = caller.relevantTokens();
        uint256[] memory a = caller.poolBalances();
        uint256[] memory idx = new uint256[](tokens.length);
        uint256[] memory w = caller.tokenWeights();
        uint256 fee1e18 = caller.fee1e9() * uint256(1e9);
        if (caller.lastWithdrawTimestamp() == block.timestamp) {
            fee1e18 = fee1e18 * caller.feeMultiplier() / 1e9;
        }
        uint256 additionalMultiplier = 1e9;

        int128[] memory r = new int128[](t.length);
        uint256 j = 1;
        for (uint256 i = 0; i < tokens.length; ++i) {
            if (tokens[i] == t.u(0)) {
                idx.u(i, 0);
                r.u(0, r_.u(i));
            } else {
                while (!(tokens[i] == t[j])) ++j;
                idx.u(i, j);
                r.u(j, r_.u(i));
            }
        }

        SD59x18[] memory logA = new SD59x18[](w.length);

        SD59x18 logInvariantMin;
        for (uint256 i = 1; i < w.length; i++) {
            a[i] += 1;
            logA[i] = log2(convert(int256(a[i])));
            logInvariantMin = logInvariantMin + (logA[i] * convert(int256(w[i])));
        }

        logInvariantMin = logInvariantMin / convert(int256(w[0]));

        SD59x18 logK;
        SD59x18 logGrowth = sd(0);
        SD59x18 sumUnknownWeight = sd(0);
        if (r[0] == type(int128).max) {
            uint256 kw = 0;
            for (uint256 i = 1; i < w.length; i++) {
                if (r[i] == type(int128).max) {
                    kw += w[i];
                    continue;
                }
                logK = logK + (convert(int256(w[i])) * (log2(convert(int256(a[i]) + r[i])) - logA[i]));
            }
            logK = logK / convert(int256(w[0] - kw));
            sumUnknownWeight = sumUnknownWeight - convert(int256(w[0]));
        } else if (r[0] != 0) {
            SD59x18 x = exp2(logInvariantMin) - convert(r[0]);
            logK = log2(x < convert(int256(1)) ? convert(int256(1)) : x) - logInvariantMin;
            if (logK < sd(0)) {
                additionalMultiplier = uint256(exp2(-logK).intoInt256() / 1e9);
            }

            logGrowth = -logK * convert(int256(w[0]));
        }

        SD59x18 k = exp2(logK);
        for (uint256 i = 1; i < w.length; i++) {
            if (r[i] == type(int128).max) {
                // unknowns
                sumUnknownWeight = sumUnknownWeight + convert(int256(w[i]));
            } else {
                SD59x18 b = convert(int256(a[i]) + r[i]);
                SD59x18 fee;
                SD59x18 a_prime = convert(int256(a[i])) * (logK > sd(0) ? sd(1e18) : k);
                SD59x18 b_prime = b / (logK > sd(0) ? k : sd(1e18));
                if (b_prime > a_prime) {
                    fee = (b_prime - a_prime) * sd(int256(fee1e18));
                }
                logGrowth = logGrowth + (convert(int256(w[i])) * (log2(b - fee) - logA[i]));
            }
        }
        SD59x18 logG = -logGrowth / sumUnknownWeight;

        for (uint256 i = 0; i < w.length; i++) {
            if (r[i] != type(int128).max) continue;
            if (i != 0) {
                SD59x18 logB = logG + logA[i] + sd(100000);
                SD59x18 b = exp2(logB);
                SD59x18 a_prime = convert(int256(a[i])) * (logK > sd(0) ? sd(1e18) : k);
                SD59x18 b_prime = b / (logK > sd(0) ? k : sd(1e18));
                if (b_prime > a_prime) {
                    b = b + ((b_prime - a_prime) / (sd(1e18) - sd(int256(fee1e18)))) - (b_prime - a_prime);
                }
                r[i] = convert(b - convert(int256(a[i]))).toInt128();
                // the case of b < 0 will be handled by the vault
            } else {
                SD59x18 logB = logG + logInvariantMin;
                r[i] = -convert(exp2(logB) - exp2(logInvariantMin)).toInt128();
                if (logG < sd(0)) {
                    additionalMultiplier = uint256(exp2(-logG).intoInt256() / 1e9);
                }
                // the case of b < 0 will be handled by the fact that the user can't provide the required LP token.
            }
        }

        if (additionalMultiplier > 1e9) {
            if (caller.lastWithdrawTimestamp() == block.timestamp) {
                caller.notifyWithdraw((additionalMultiplier * caller.feeMultiplier() / 1e9).toUint128());
            } else {
                caller.notifyWithdraw(additionalMultiplier.toUint128());
            }
        }
        if (r.u(0) > 0) {
            ConstantProductPool(msg.sender).notifyBurn(uint128(r.u(0)));
        } else if (r.u(0) < 0) {
            ConstantProductPool(msg.sender).notifyMint(uint128(-r.u(0)));
        }
        for (uint256 i = 0; i < tokens.length; i++) {
            r_.u(i, r.u(idx.u(i)));
        }
        return (new int128[](tokens.length), r_);
    }
}
