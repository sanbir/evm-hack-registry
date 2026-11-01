// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity >=0.8.0;
pragma abicoder v2;

import {YapePair} from "./YapePair.sol";

contract YapePairCode {
    function getCreationCode() public pure returns (bytes memory) {
        return type(YapePair).creationCode;
    }
}
