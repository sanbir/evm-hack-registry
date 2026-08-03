// SPDX-License-Identifier: MIT
pragma solidity =0.7.6;
pragma experimental ABIEncoderV2;

import {AppStorage} from "../beanstalk/AppStorage.sol";
import {LibAppStorage} from "../libraries/LibAppStorage.sol";
import "../libraries/LibSafeMathSigned96.sol";

/**
 * @title LibTokenSiloV1
 * @notice VERBATIM extract of `stemTipForToken` from the PRE-UPGRADE Beanstalk
 *         source at commit 76066733bcddb944b9af8f29acf150c02a5b8437
 *         (protocol/contracts/libraries/Silo/LibTokenSilo.sol).
 *
 *         The ONLY change vs the audited source is the library symbol name
 *         (`LibTokenSilo` -> `LibTokenSiloV1`), required so the pre-upgrade and
 *         post-upgrade versions can coexist in one compilation unit. The
 *         function body is byte-identical to the audited code.
 *
 *         Key property (the bug): `milestoneStem` is added at TRUNCATED scale
 *         (NOT divided by 1e6), only the second term is divided by 1e6.
 */
library LibTokenSiloV1 {
    using LibSafeMathSigned96 for int96;

    function stemTipForToken(address token)
        internal
        view
        returns (int96 _stemTipForToken)
    {
        AppStorage storage s = LibAppStorage.diamondStorage();

        // SafeCast unnecessary because all casted variables are types smaller that int96.
        _stemTipForToken = s.ss[token].milestoneStem +
        int96(s.ss[token].stalkEarnedPerSeason).mul(
            int96(s.season.current).sub(int96(s.ss[token].milestoneSeason))
        ).div(1e6); //round here
    }
}
