// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.6;

import {CircomData} from "./CircomData.sol";

interface IPreTransactHook {
    function preTransact(CircomData calldata circomData) external;
}

interface ITransactHook {
    function afterTransact(CircomData calldata circomData) external;
}
