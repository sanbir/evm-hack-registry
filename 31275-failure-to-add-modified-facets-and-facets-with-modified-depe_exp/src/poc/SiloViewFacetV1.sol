// SPDX-License-Identifier: MIT
pragma solidity =0.7.6;
pragma experimental ABIEncoderV2;

import {ReentrancyGuard} from "../beanstalk/ReentrancyGuard.sol";
import {LibTokenSiloV1} from "./LibTokenSiloV1.sol";
import {LibSiloView} from "./LibSiloView.sol";

/**
 * @title SiloViewFacetV1
 * @notice Thin facet that exposes the exact `stemTipForToken` and
 *         `balanceOfGrownStalk` public functions from the PRE-UPGRADE
 *         Beanstalk `SiloExit` (protocol/contracts/beanstalk/silo/SiloFacet/SiloExit.sol
 *         at 76066733). Function bodies are copied verbatim from SiloExit; the
 *         grown-stalk / stem math lives in the real audited libraries
 *         (LibTokenSiloV1 / LibSiloView).
 *
 *         This is the facet that BIP-39 FAILED to re-cut. Because it inlines
 *         LibTokenSiloV1 (which adds `milestoneStem` un-divided), after the
 *         upgrade rescales `milestoneStem` untruncated, its results become
 *         ~1e6x too large.
 */
contract SiloViewFacetV1 is ReentrancyGuard {
    function stemTipForToken(address token)
        public
        view
        returns (int96 _stemTip)
    {
        _stemTip = LibTokenSiloV1.stemTipForToken(
            token
        );
    }

    function balanceOfGrownStalk(address account, address token)
        public
        view
        returns (uint256)
    {
        return
            LibSiloView._balanceOfGrownStalk(
                s.a[account].mowStatuses[token].lastStem, //last stem farmer mowed
                LibTokenSiloV1.stemTipForToken(token), //get latest stem for this token
                s.a[account].mowStatuses[token].bdv
            );
    }
}
