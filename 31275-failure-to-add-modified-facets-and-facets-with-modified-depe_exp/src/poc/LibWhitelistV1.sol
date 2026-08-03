// SPDX-License-Identifier: MIT
pragma solidity =0.7.6;
pragma experimental ABIEncoderV2;

import {AppStorage} from "../beanstalk/AppStorage.sol";
import {LibAppStorage} from "../libraries/LibAppStorage.sol";
import {LibTokenSiloV1} from "./LibTokenSiloV1.sol";

/**
 * @title LibWhitelistV1
 * @notice VERBATIM extract of `updateStalkPerBdvPerSeasonForToken` from the
 *         PRE-UPGRADE Beanstalk source at commit
 *         76066733bcddb944b9af8f29acf150c02a5b8437
 *         (protocol/contracts/libraries/Silo/LibWhitelist.sol).
 *
 *         Stores `milestoneStem` via LibTokenSilo.stemTipForToken() -> TRUNCATED.
 */
library LibWhitelistV1 {
    event UpdatedStalkPerBdvPerSeason(
        address indexed token,
        uint32 stalkEarnedPerSeason,
        uint32 season
    );

    function updateStalkPerBdvPerSeasonForToken(
        address token,
        uint32 stalkEarnedPerSeason
    ) internal {
        AppStorage storage s = LibAppStorage.diamondStorage();

        require(s.ss[token].milestoneSeason != 0, "Token not whitelisted");

        s.ss[token].milestoneStem = LibTokenSiloV1.stemTipForToken(token); //store grown stalk milestone
        s.ss[token].milestoneSeason = s.season.current; //update milestone season as this season
        s.ss[token].stalkEarnedPerSeason = stalkEarnedPerSeason;

        emit UpdatedStalkPerBdvPerSeason(token, stalkEarnedPerSeason, s.season.current);
    }
}
