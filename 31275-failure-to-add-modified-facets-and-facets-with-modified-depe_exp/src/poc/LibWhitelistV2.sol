// SPDX-License-Identifier: MIT
pragma solidity =0.7.6;
pragma experimental ABIEncoderV2;

import {AppStorage} from "../beanstalk/AppStorage.sol";
import {LibAppStorage} from "../libraries/LibAppStorage.sol";
import {LibTokenSiloV2} from "./LibTokenSiloV2.sol";

/**
 * @title LibWhitelistV2
 * @notice VERBATIM extract of `updateStalkPerBdvPerSeasonForToken` from the
 *         BIP-39 Beanstalk source at commit
 *         dfb418d185cd93eef08168ccaffe9de86bc1f062
 *         (protocol/contracts/libraries/Silo/LibWhitelist.sol).
 *
 *         Stores `milestoneStem` via LibTokenSilo.stemTipForTokenUntruncated()
 *         -> UNTRUNCATED (~1e6x larger than the V1 store). This is the storage
 *         write that becomes inconsistent with the stale V1 SiloFacet.
 */
library LibWhitelistV2 {
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

        s.ss[token].milestoneStem = LibTokenSiloV2.stemTipForTokenUntruncated(token); // store grown stalk milestone
        s.ss[token].milestoneSeason = s.season.current; // update milestone season as this season
        s.ss[token].stalkEarnedPerSeason = stalkEarnedPerSeason;

        emit UpdatedStalkPerBdvPerSeason(token, stalkEarnedPerSeason, s.season.current);
    }
}
