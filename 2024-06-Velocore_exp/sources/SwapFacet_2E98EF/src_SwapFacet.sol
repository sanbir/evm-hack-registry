// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.19;

import "src/lib/Token.sol";
import "src/lib/PoolBalanceLib.sol";
import "src/interfaces/IPool.sol";
import "src/interfaces/ISwap.sol";
import "src/interfaces/IConverter.sol";
import "src/interfaces/IVC.sol";
import "src/interfaces/IVault.sol";
import "src/interfaces/IFacet.sol";
import "src/VaultStorage.sol";
import "openzeppelin-contracts/contracts/utils/math/SafeCast.sol";
import "openzeppelin-contracts/contracts/utils/math/Math.sol";

uint256 constant GAUGE_FLAG_KILLED = 1;

/**
 * @dev a Facet for handling swap, stake and vote logic.
 *
 *
 * please refer to the tech docs below for its intended behavior.
 * https://velocore.gitbook.io/velocore-v2/technical-docs/exchanging-tokens-with-vault
 *
 *
 */
contract SwapFacet is VaultStorage, IFacet {
    using PoolBalanceLib for PoolBalance;
    using TokenLib for Token;
    using UncheckedMemory for Token[];
    using UncheckedMemory for int128[];
    using UncheckedMemory for bytes32[];
    using UncheckedMemory for uint256[];
    using SafeCast for uint256;
    using SafeCast for int256;
    using EnumerableSet for EnumerableSet.AddressSet;

    IVC immutable vc;
    Token immutable ballot; // veVC
    address immutable thisImplementation;

    constructor(IVC vc_, Token ballot_) {
        vc = vc_;
        ballot = ballot_;
        thisImplementation = address(this);
    }

    /**
     * @dev called by AdminFacet.admin_addFacet().
     * doesnt get added to the routing table, hence the lack of access control.
     */
    function initializeFacet() external {
        _setFunction(SwapFacet.execute.selector, thisImplementation);

        // set as viewer; meaning its state alteration will not last.
        // This allows query() to make actually perform swaps without any security consequences.
        _setViewer(SwapFacet.query.selector, thisImplementation);
        _setViewer(SwapFacet.balanceDelta.selector, thisImplementation);
    }

    /**
     * @dev the primary function for exchanging tokens.
     * @param tokenRef list of unique tokens involved in the operations. preferrably sorted.
     * @param deposit list of amounts, in the same order as tokenRef, that will be transferFrom()'ed before execution.
     *                allows selling of tax tokens.
     * @param ops please refer to the tech docs.
     */
    function execute(Token[] memory tokenRef, int128[] memory deposit, VelocoreOperation[] memory ops)
        external
        payable
        nonReentrant
        returns (int128[] memory)
    {
        uint256 tokenRefLength = tokenRef.length;
        require(tokenRefLength == deposit.length && tokenRefLength < 256, "malformed array");

        /**
         * to gurantee uniqueness and binary-searchability, tokenRef and VelocoreOperation.tokenInformation must be sorted first.
         * We perform insertion sort to allow sorting off-chain to save gas.
         */
        (bool orderChanged,, uint256[] memory toNewIdx) = _sort(tokenRef, deposit, ops);

        /**
         * transfer (deposit[]) amount of tokens from the user and credit them.
         * we are using deposit[] to track internal balance here.
         */
        unchecked {
            for (uint256 i = 0; i < tokenRefLength; ++i) {
                int128 d = deposit.u(i);
                require(d >= 0);
                if (d > 0) {
                    deposit.u(
                        i,
                        int128(
                            uint128(tokenRef.u(i).meteredTransferFrom(msg.sender, address(this), uint256(int256(d))))
                        )
                    );
                }
            }
        }

        /**
         * credit msg.value to the internal balance.
         * we are using deposit[] to track internal balance here.
         */
        if (msg.value > 0) {
            deposit.u(_binarySearchM(tokenRef, NATIVE_TOKEN), msg.value.toInt256().toInt128());
        }

        /**
         * actually calculate exchange. deposit[] will be modified in-place to represent the user's internal balance.
         */
        _execute(msg.sender, tokenRef, deposit, ops);

        /**
         * transfer the internal balance back to the user.
         */
        unchecked {
            for (uint256 i = 0; i < tokenRefLength; ++i) {
                int128 d = deposit.u(i);
                if (d == 0) {
                    continue;
                } else if (d > 0) {
                    tokenRef.u(i).transferFrom(address(this), msg.sender, uint256(int256(d)));
                } else {
                    tokenRef.u(i).safeTransferFrom(msg.sender, address(this), uint256(int256(-d)));
                }
            }
        }
        if (orderChanged) {
            int128[] memory ret = new int128[](tokenRef.length);
            for (uint256 i = 0; i < ret.length; i++) {
                ret[i] = deposit[toNewIdx[i]];
            }
            return ret;
        } else {
            return deposit;
        }
    }

    /**
     * @dev actually perform operations and return their result.
     * this function modifies states
     * this function is not intended to be added as a viewer function. see initializeFacet() above for explanation.
     */
    function query(address user, Token[] memory tokenRef, int128[] memory deposit, VelocoreOperation[] memory ops)
        external
        nonReentrant
        returns (int128[] memory)
    {
        require(tokenRef.length == deposit.length && tokenRef.length < 256, "malformed input");
        (bool orderChanged,, uint256[] memory toNewIdx) = _sort(tokenRef, deposit, ops);

        _execute(user, tokenRef, deposit, ops);
        if (orderChanged) {
            int128[] memory ret = new int128[](tokenRef.length);
            for (uint256 i = 0; i < ret.length; i++) {
                ret[i] = deposit[toNewIdx[i]];
            }
            return ret;
        } else {
            return deposit;
        }
    }

    /**
     * the core logic, called from query() and execute()
     * using cumDelta as internal balance.
     */
    function _execute(address user, Token[] memory tokenRef, int128[] memory cumDelta, VelocoreOperation[] memory ops)
        internal
    {
        bool vcDispensed = false;
        for (uint256 i = 0; i < ops.length; i++) {
            VelocoreOperation memory op = ops[i];
            bytes32[] memory opTokenInformations = op.tokenInformations;
            uint256 opTokenLength = opTokenInformations.length;
            Token[] memory opTokens = new Token[](opTokenLength);
            int128[] memory opAmounts = new int128[](opTokenLength);
            unchecked {
                for (uint256 j = 0; j < opTokenLength; j++) {
                    bytes32 tokInfo = opTokenInformations.u(j);
                    uint8 tokenIndex = uint8(tokInfo[0]);
                    uint8 amountType = uint8(tokInfo[1]);

                    opTokens.u(j, tokenRef.u(tokenIndex));
                    if (amountType == 0) {
                        // equals
                        opAmounts.u(j, int128(uint128(uint256(tokInfo))));
                    } else if (amountType == 1) {
                        // at most
                        opAmounts.u(j, type(int128).max);
                    } else if (amountType == 2) {
                        // consume all
                        opAmounts.u(j, cumDelta.u(tokenIndex));
                    } else if (amountType == 3) {
                        // everything
                        opAmounts.u(
                            j,
                            int128(
                                int256(
                                    Math.min(
                                        opTokens.u(j).balanceOf(address(this)), uint256(int256(type(int128).max)) - 1
                                    )
                                )
                            )
                        );
                    }
                }
            }

            uint8 opType = uint8(op.poolId[0]);
            address opDst = address(uint160(uint256(op.poolId)));

            if (opType == 0) {
                // swap
                (int128[] memory deltaGauge, int128[] memory deltaPool) =
                    ISwap(opDst).velocore__execute(user, opTokens, opAmounts, op.data);
                require(deltaGauge.length == opTokenLength && deltaPool.length == opTokenLength);
                _verifyAndApplyDelta(cumDelta, IPool(opDst), opTokens, opTokenInformations, deltaGauge, deltaPool);
                unchecked {
                    for (uint256 j = 0; j < opTokenLength; j++) {
                        deltaGauge.u(j, deltaPool.u(j) + deltaGauge.u(j));
                    }
                }
                emit Swap(ISwap(opDst), user, opTokens, deltaGauge);
            } else if (opType == 1) {
                // stake
                if (!vcDispensed) {
                    _dispenseVC();
                    vcDispensed = true;
                }
                _sendEmission(IGauge(opDst));
                (int128[] memory deltaGauge, int128[] memory deltaPool) =
                    IGauge(opDst).velocore__gauge(user, opTokens, opAmounts, op.data);

                require(deltaGauge.length == opTokenLength && deltaPool.length == opTokenLength);
                _verifyAndApplyDelta(cumDelta, IPool(opDst), opTokens, opTokenInformations, deltaGauge, deltaPool);
                unchecked {
                    for (uint256 j = 0; j < opTokenLength; j++) {
                        deltaGauge.u(j, deltaPool.u(j) + deltaGauge.u(j));
                    }
                }
                emit Gauge(IGauge(opDst), user, opTokens, deltaGauge);
            } else if (opType == 2) {
                // convert

                uint256[] memory balances = new uint256[](opTokenLength);
                for (uint256 j = 0; j < opTokenLength; j++) {
                    balances.u(j, opTokens.u(j).balanceOf(address(this)));
                    if (opAmounts.u(j) <= 0 || opAmounts.u(j) == type(int128).max) continue;
                    opTokens.u(j).transferFrom(address(this), opDst, uint128(uint256(int256(opAmounts.u(j)))));
                }

                IConverter(opDst).velocore__convert(user, opTokens, opAmounts, op.data);

                int128[] memory deltas = SwapFacet(address(this)).balanceDelta(opTokens, balances);
                for (uint256 j = 0; j < opTokenLength; j++) {
                    require(-deltas.u(j) <= int128(uint128(uint256(opTokenInformations.u(j)))));
                    cumDelta[uint8(uint256(opTokenInformations.u(j) >> (256 - 8)))] += deltas.u(j);
                    deltas.u(j, -deltas.u(j));
                }
                emit Convert(IConverter(opDst), user, opTokens, deltas);
            } else if (opType == 3) {
                // vote
                if (!vcDispensed) {
                    _dispenseVC();
                    vcDispensed = true;
                }
                _sendEmission(IGauge(opDst));
                GaugeInformation storage gauge = _e().gauges[IGauge(opDst)];
                if (gauge.lastBribeUpdate == 0) gauge.lastBribeUpdate = uint32(block.timestamp);
                if (gauge.lastBribeUpdate > 1) {
                    uint256 elapsed = block.timestamp - gauge.lastBribeUpdate;
                    if (elapsed > 0) {
                        uint256 len = gauge.bribes.length();
                        for (uint256 j = 0; j < len; j++) {
                            bytes memory extortCalldata = abi.encodeWithSelector(
                                SwapFacet.extort.selector, j, tokenRef, cumDelta, IGauge(opDst), elapsed, user
                            );
                            address thisImpl = thisImplementation;
                            bool success;
                            assembly ("memory-safe") {
                                success :=
                                    delegatecall(gas(), thisImpl, add(extortCalldata, 32), mload(extortCalldata), 0, 0)
                                if success { returndatacopy(add(cumDelta, 32), 0, mul(32, mload(cumDelta))) }
                            }
                        }
                    }

                    gauge.lastBribeUpdate = uint32(block.timestamp);
                }
                uint256 ballotIndex = _binarySearchM(opTokens, ballot);
                int128 deltaVote;
                if (ballotIndex != type(uint256).max) {
                    deltaVote = opAmounts.u(ballotIndex);
                    if (deltaVote != type(int128).max) {
                        gauge.totalVotes = (int256(uint256(gauge.totalVotes)) + deltaVote).toUint256().toUint112();
                        _e().totalVotes = (int256(uint256(_e().totalVotes)) + deltaVote).toUint256().toUint128();
                        gauge.userVotes[user] =
                            (int256(uint256(gauge.userVotes[user])) + deltaVote).toUint256().toUint128();
                        cumDelta[_binarySearchM(tokenRef, ballot)] -= deltaVote;
                    } else {
                        deltaVote = 0;
                    }
                }
                emit Vote(IGauge(opDst), user, deltaVote);
            } else if (opType == 4) {
                bool isUser = user == opDst;
                for (uint256 j = 0; j < opTokenLength; j++) {
                    require(isUser || opAmounts[j] >= 0, "you can't withdraw other's balance");
                    _userBalances()[opDst][opTokens[j]] =
                        (int256(_userBalances()[opDst][opTokens[j]]) + opAmounts[j]).toUint256();
                    cumDelta[uint8(uint256(opTokenInformations.u(j) >> (256 - 8)))] -= opAmounts[j];
                }
                emit UserBalance(opDst, user, opTokens, opAmounts);
            } else if (opType == 5) {
                unchecked {
                    for (uint256 j = 0; j < opTokenLength; j++) {
                        require(
                            int128(uint128(uint256(opTokenInformations.u(j))))
                                >= -cumDelta[uint8(uint256(opTokenInformations.u(j) >> (256 - 8)))],
                            "sippage"
                        );
                    }
                }
            } else {
                revert();
            }
        }
    }

    function balanceDelta(Token[] memory tokens, uint256[] memory balancesBefore)
        external
        returns (int128[] memory delta)
    {
        delta = new int128[](tokens.length);
        for (uint256 i = 0; i < tokens.length; i++) {
            int128 diff = (tokens.u(i).balanceOf(address(this)).toInt256() - balancesBefore.u(i).toInt256()).toInt128();
            delta.u(i, diff);
            if (diff > 0) {
                tokens.u(i).transferFrom(address(this), address(0xDEADBEEF), uint256(int256(diff)));
            }
        }
    }

    function extort(
        uint256 bribeIndex,
        Token[] calldata tokenRef,
        int128[] memory cumDelta,
        IGauge gauge,
        uint256 elapsed,
        address user
    ) external payable {
        IBribe briber = IBribe(_e().gauges[gauge].bribes.at(bribeIndex));
        (
            Token[] memory bribeTokens,
            int128[] memory deltaGauge,
            int128[] memory deltaPool,
            int128[] memory deltaExternal
        ) = briber.velocore__bribe(gauge, elapsed);
        require(
            bribeTokens.length == deltaGauge.length && bribeTokens.length == deltaPool.length
                && bribeTokens.length == deltaExternal.length
        );
        for (uint256 j = 0; j < bribeTokens.length; j++) {
            uint256 netDelta = (-(int256(deltaGauge.u(j)) + deltaPool.u(j) + deltaExternal.u(j))).toUint256();
            Token token = bribeTokens.u(j);
            require(deltaExternal[j] <= 0);
            _modifyPoolBalance(briber, token, deltaGauge.u(j), deltaPool.u(j), deltaExternal.u(j));

            GaugeInformation storage g = _e().gauges[gauge];
            Rewards storage r = g.rewards[briber][token];

            if (g.totalVotes > 0) {
                r.current += netDelta * 1e18 / g.totalVotes;
            } else {
                unchecked {
                    _userBalances()[StorageSlot.getAddressSlot(SSLOT_HYPERCORE_TREASURY).value][token] += netDelta;
                }
            }

            uint256 userClaimed = (r.current - r.snapshots[user]) * uint256(g.userVotes[user]) / 1e18;
            uint256 index = _binarySearch(tokenRef, token);
            r.snapshots[user] = r.current;

            if (index != type(uint256).max) {
                cumDelta[index] += userClaimed.toInt256().toInt128();
            } else {
                _userBalances()[user][token] += userClaimed;
            }
        }
        assembly ("memory-safe") {
            return(add(cumDelta, 32), mul(32, mload(cumDelta)))
        }
    }

    /**
     * @dev in-place sort for execute() inputs.
     *
     * To gurantee uniqueness and binary-searchability, tokenRef and VelocoreOperation.tokenInformation must be sorted first.
     * We perform insertion sort to allow sorting off-chain to save gas.
     *
     * @return orderChanged wether the orignal input was already sorted
     * @return toOldIdx mapping(new index => old index)
     * @return toNewIdx mapping(old index => new index); valid only when orderChanged == true;
     */
    function _sort(Token[] memory tokens, int128[] memory amounts, VelocoreOperation[] memory ops)
        internal
        returns (bool orderChanged, uint256[] memory toOldIdx, uint256[] memory toNewIdx)
    {
        toOldIdx = new uint256[](tokens.length);
        toNewIdx = new uint256[](tokens.length);
        orderChanged = false;
        uint256 tokenRefLength = tokens.length;
        uint256 opsLength = ops.length;
        unchecked {
            /**
             * Perform insertion sort on tokenRef first
             */
            for (uint256 i = 1; i < tokenRefLength; ++i) {
                toOldIdx.u(i, i);
                Token key = tokens.u(i);
                // using (<=) instead of (<) to include cases with duplicated tokens
                if (key <= tokens.u(i - 1)) {
                    int128 amt = amounts.u(i);
                    uint256 j = i;
                    orderChanged = true;
                    while (j >= 1 && key <= tokens.u(j - 1)) {
                        --j;
                        tokens.u(j + 1, tokens.u(j));
                        toOldIdx.u(j + 1, toOldIdx.u(j));
                        amounts.u(j + 1, amounts.u(j));
                    }
                    require(tokenRefLength - 1 == j || tokens.u(j + 1) != key, "duplicated token");
                    tokens.u(j, key);
                    toOldIdx.u(j, i);
                    amounts.u(j, amt);
                }
            }

            /**
             * compute toNewIdx only when orderChanged
             */
            if (orderChanged) {
                for (uint256 i = 0; i < tokenRefLength; ++i) {
                    toNewIdx.u(toOldIdx.u(i), i);
                }
            }

            /**
             * perform insertion sort on VelocoreOperation[].tokenInforamtion
             */
            for (uint256 i = 0; i < opsLength; ++i) {
                bytes32[] memory arr = ops[i].tokenInformations;
                uint256 tokenInformationLength = arr.length;
                for (uint256 j = 0; j < tokenInformationLength; ++j) {
                    bytes32 key;
                    if (orderChanged) {
                        uint8 oldIdx = uint8(arr.u(j)[0]);
                        // toNewIdx.length could be lower than oldIdx; using boundedness check here.
                        key = (
                            (arr.u(j) & 0x00FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF)
                                | bytes32(bytes1(uint8(toNewIdx[oldIdx])))
                        );
                        arr.u(j, key);
                    } else {
                        key = arr.u(j);
                    }
                    uint256 k = j;
                    if (k >= 1 && key[0] <= arr.u(k - 1)[0]) {
                        while (k >= 1 && key[0] <= arr.u(k - 1)[0]) {
                            --k;
                            arr.u(k + 1, arr.u(k));
                        }
                        require(
                            arr.length - 1 == k || arr.u(k + 1)[0] != key[0], "duplicated token in VelocoreOperation"
                        );
                        arr.u(k, key);
                    }
                }
                require(
                    tokenInformationLength == 0 || uint8(arr.u(tokenInformationLength - 1)[0]) < tokenRefLength,
                    "token not in tokenRef"
                );
            }
        }
    }

    function _modifyPoolBalance(IPool pool, Token tok, int128 dGauge, int128 dPool, int128 dExternal) internal {
        _poolBalances()[pool][tok] = _poolBalances()[pool][tok].credit(dGauge, dPool);

        if (dExternal < 0) {
            tok.safeTransferFrom(address(pool), address(this), uint256(int256(-dExternal)));
        }
        // we don't implement (dExternal > 0), as such cases will not happen.
    }

    function _dispenseVC() internal {
        if (_e().totalVotes > 0) {
            uint256 dispensed = vc.dispense();
            if (dispensed > 0) {
                _e().perVote = _e().perVote + (uint256(1e9) * dispensed / _e().totalVotes).toUint128();
            }
        }
    }

    function _sendEmission(IGauge gauge) internal {
        uint256 newEmissions;
        if (_e().gauges[gauge].lastBribeUpdate == 1) {
            newEmissions = 0;
        } else {
            newEmissions = uint256(_e().perVote - _e().gauges[gauge].perVoteAtLastEmissionUpdate)
                * _e().gauges[gauge].totalVotes / 1e9;

            // overflow should not happen, as (perVote / 1e9) should be much lower than 200 according to the tokenmics.
            // log2(1e18 * 1e9 * 1e3) = 99.7 < 112
            _e().gauges[gauge].perVoteAtLastEmissionUpdate = uint112(_e().perVote);
        }
        _poolBalances()[gauge][toToken(vc)] = _poolBalances()[gauge][toToken(vc)].credit(int256(newEmissions), 0);
        gauge.velocore__emission(newEmissions);
    }

    function _verifyAndApplyDelta(
        int128[] memory cumDelta,
        IPool pool,
        Token[] memory opTokens,
        bytes32[] memory tokenInformations,
        int128[] memory deltaGauge,
        int128[] memory deltaPool
    ) internal {
        uint256 opTokenLength = opTokens.length;
        for (uint256 j = 0; j < opTokenLength; j++) {
            int128 dg = deltaGauge.u(j);
            int128 dp = deltaPool.u(j);
            int128 d = dg + dp;
            require(d <= int128(uint128(uint256(tokenInformations.u(j)))), "token result above max");
            Token token = opTokens.u(j);
            _modifyPoolBalance(pool, token, dg, dp, 0);
            cumDelta[uint8(tokenInformations.u(j)[0])] -= d;
        }
    }
}
