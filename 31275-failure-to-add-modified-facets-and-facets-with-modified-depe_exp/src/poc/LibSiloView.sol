// SPDX-License-Identifier: MIT
pragma solidity =0.7.6;
pragma experimental ABIEncoderV2;

import "../libraries/LibSafeMathSigned96.sol";

/**
 * @title LibSiloView
 * @notice VERBATIM extract of `_balanceOfGrownStalk` and `stalkReward` from the
 *         Beanstalk source (protocol/contracts/libraries/Silo/LibSilo.sol).
 *         Identical in both the pre-upgrade (76066733) and BIP-39 (dfb418d)
 *         commits -- the grown-stalk formula did not change; only the stem-tip
 *         SCALE fed into it changed (see LibTokenSiloV1/V2).
 *
 *         grownStalk = (endStem - startStem) * bdv
 */
library LibSiloView {
    using LibSafeMathSigned96 for int96;

    function _balanceOfGrownStalk(
        int96 lastStem,
        int96 latestStem,
        uint128 bdv
    ) internal pure returns (uint256)
    {
        return stalkReward(lastStem, latestStem, bdv);
    }

    function stalkReward(int96 startStem, int96 endStem, uint128 bdv) //are the types what we want here?
        internal
        pure
        returns (uint256)
    {
        int96 reward = endStem.sub(startStem).mul(int96(bdv));

        return uint128(reward);
    }
}
