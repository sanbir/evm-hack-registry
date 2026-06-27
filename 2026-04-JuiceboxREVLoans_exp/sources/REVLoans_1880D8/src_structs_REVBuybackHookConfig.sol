// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {IJBBuybackHook} from "@bananapus/buyback-hook-v5/src/interfaces/IJBBuybackHook.sol";
import {IJBRulesetDataHook} from "@bananapus/core-v5/src/interfaces/IJBRulesetDataHook.sol";

import {REVBuybackPoolConfig} from "./REVBuybackPoolConfig.sol";

/// @custom:member dataHook The data hook to use.
/// @custom:member hookToConfigure The buyback hook to configure.
/// @custom:member poolConfigurations The pools to setup on the given buyback contract.
struct REVBuybackHookConfig {
    IJBRulesetDataHook dataHook;
    IJBBuybackHook hookToConfigure;
    REVBuybackPoolConfig[] poolConfigurations;
}
