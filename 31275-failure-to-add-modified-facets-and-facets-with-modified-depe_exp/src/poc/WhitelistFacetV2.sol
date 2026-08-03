// SPDX-License-Identifier: MIT
pragma solidity =0.7.6;
pragma experimental ABIEncoderV2;

import {ReentrancyGuard} from "../beanstalk/ReentrancyGuard.sol";
import {LibWhitelistV2} from "./LibWhitelistV2.sol";

/**
 * @title WhitelistFacetV2
 * @notice Exposes the milestone-writer `updateStalkPerBdvPerSeasonForToken`
 *         using the BIP-39 LibWhitelistV2 (stores milestoneStem UNTRUNCATED).
 *         This is the facet that IS re-cut by the BIP-39 upgrade. It writes the
 *         new-scale milestoneStem that the stale V1 SiloFacet misreads.
 */
contract WhitelistFacetV2 is ReentrancyGuard {
    function updateStalkPerBdvPerSeasonForToken(
        address token,
        uint32 stalkEarnedPerSeason
    ) external {
        LibWhitelistV2.updateStalkPerBdvPerSeasonForToken(token, stalkEarnedPerSeason);
    }
}
