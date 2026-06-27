// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import {ActionsBitmap} from "@size/src/factory/libraries/Authorization.sol";

interface IRequiresAuthorization {
    function getActionsBitmap() external view returns (ActionsBitmap);
}
