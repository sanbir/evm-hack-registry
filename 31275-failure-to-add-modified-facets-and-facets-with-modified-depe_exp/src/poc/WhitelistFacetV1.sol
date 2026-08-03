// SPDX-License-Identifier: MIT
pragma solidity =0.7.6;
pragma experimental ABIEncoderV2;

import {ReentrancyGuard} from "../beanstalk/ReentrancyGuard.sol";
import {LibWhitelistV1} from "./LibWhitelistV1.sol";

/**
 * @title WhitelistFacetV1
 * @notice Exposes the milestone-writer `updateStalkPerBdvPerSeasonForToken`
 *         using the PRE-UPGRADE LibWhitelistV1 (stores milestoneStem truncated).
 *         In Beanstalk this milestone write is driven by SeasonFacet/LibGauge
 *         during sunrise; here it is exposed directly so the PoC can trigger it.
 */
contract WhitelistFacetV1 is ReentrancyGuard {
    function updateStalkPerBdvPerSeasonForToken(
        address token,
        uint32 stalkEarnedPerSeason
    ) external {
        LibWhitelistV1.updateStalkPerBdvPerSeasonForToken(token, stalkEarnedPerSeason);
    }
}
