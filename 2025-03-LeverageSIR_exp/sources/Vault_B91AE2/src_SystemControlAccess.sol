// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

// import {SystemConstants} from "./libraries/SystemConstants.sol";

contract SystemControlAccess {
    address internal immutable SYSTEM_CONTROL;

    modifier onlySystemControl() {
        require(msg.sender == SYSTEM_CONTROL);
        _;
    }

    constructor(address systemControl) {
        SYSTEM_CONTROL = systemControl;
    }
}
