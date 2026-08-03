// SPDX-License-Identifier: MIT
pragma solidity =0.7.6;
pragma experimental ABIEncoderV2;

import {ReentrancyGuard} from "../beanstalk/ReentrancyGuard.sol";
import {LibTokenSiloV2} from "./LibTokenSiloV2.sol";
import {LibSiloView} from "./LibSiloView.sol";

/**
 * @title SiloViewFacetV2
 * @notice Same public surface as SiloViewFacetV1, but inlines LibTokenSiloV2
 *         (the BIP-39 stem math that divides the whole untruncated sum by 1e6).
 *         This is the facet BIP-39 SHOULD have re-cut. Used in the control run
 *         to show the correct, backward-compatible grown-stalk value.
 */
contract SiloViewFacetV2 is ReentrancyGuard {
    function stemTipForToken(address token)
        public
        view
        returns (int96 _stemTip)
    {
        _stemTip = LibTokenSiloV2.stemTipForToken(
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
                LibTokenSiloV2.stemTipForToken(token), //get latest stem for this token
                s.a[account].mowStatuses[token].bdv
            );
    }
}
