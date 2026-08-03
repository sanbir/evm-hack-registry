// SPDX-License-Identifier: MIT
pragma solidity =0.7.6;
pragma experimental ABIEncoderV2;

import {AppStorage} from "../beanstalk/AppStorage.sol";
import {LibAppStorage} from "../libraries/LibAppStorage.sol";
import "../libraries/LibSafeMathSigned96.sol";

/**
 * @title LibTokenSiloV2
 * @notice VERBATIM extract of `stemTipForTokenUntruncated` + `stemTipForToken`
 *         from the BIP-39 Beanstalk source at commit
 *         dfb418d185cd93eef08168ccaffe9de86bc1f062
 *         (protocol/contracts/libraries/Silo/LibTokenSilo.sol).
 *
 *         The ONLY change vs the audited source is the library symbol name
 *         (`LibTokenSilo` -> `LibTokenSiloV2`). Function bodies are byte-identical.
 *
 *         Key property: BIP-39 stores `milestoneStem` at UNTRUNCATED scale
 *         (see LibWhitelistV2), so the whole sum is divided by 1e6 here.
 */
library LibTokenSiloV2 {
    using LibSafeMathSigned96 for int96;

    /**
     * @dev returns the cumulative stalk per BDV (stemTip) for a whitelisted token.
     * Does not truncate the value, i.e. divide by 1e6
     */
    function stemTipForTokenUntruncated(address token)
        internal
        view
        returns (int96 _stemTipForToken)
    {
        AppStorage storage s = LibAppStorage.diamondStorage();

        // SafeCast unnecessary because all casted variables are types smaller that int96.
        _stemTipForToken = s.ss[token].milestoneStem +
        int96(s.ss[token].stalkEarnedPerSeason).mul(
            int96(s.season.current).sub(int96(s.ss[token].milestoneSeason))
        );
    }

    /**
     * @dev returns the cumulative stalk per BDV (stemTip) for a whitelisted token.
     */
    function stemTipForToken(address token)
        internal
        view
        returns (int96 _stemTipForToken)
    {
        return stemTipForTokenUntruncated(token).div(1e6);
    }
}
