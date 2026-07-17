// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.6;

import {CircomData} from "./CircomData.sol";
import {UTXO} from "./UTXO.sol";

interface IExternalActionV2 {
    function runAction(
        CircomData calldata circomData,
        int256[] calldata deltaAmountChanges
    ) external returns (UTXO[] memory);
}
