// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {IJBCashOutHook} from "@bananapus/core-v5/src/interfaces/IJBCashOutHook.sol";
import {IJBDirectory} from "@bananapus/core-v5/src/interfaces/IJBDirectory.sol";
import {IJBPayHook} from "@bananapus/core-v5/src/interfaces/IJBPayHook.sol";
import {IJBRulesetDataHook} from "@bananapus/core-v5/src/interfaces/IJBRulesetDataHook.sol";

interface IJB721Hook is IJBRulesetDataHook, IJBPayHook, IJBCashOutHook {
    function DIRECTORY() external view returns (IJBDirectory);
    function METADATA_ID_TARGET() external view returns (address);
    function PROJECT_ID() external view returns (uint256);
}
