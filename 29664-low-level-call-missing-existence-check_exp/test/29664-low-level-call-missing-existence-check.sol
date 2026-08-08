// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

contract Exploit {
    bool public callbackReportedSuccess;
    bool public stateChangeObserved;
    bool public confirmed;

    function functionDelegateCallUnverified(address target, bytes memory data)
        public
        returns (bytes memory)
    {
        (bool success, bytes memory returndata) = target.delegatecall(data);
        // @> VULN: no target.code.length check is made before accepting success.
        if (success) {
            return returndata;
        }
        revert("delegatecall failed");
    }

    function run() external {
        bytes memory empty;
        functionDelegateCallUnverified(address(0xBEEF), empty);
        callbackReportedSuccess = true;
        stateChangeObserved = false;
        require(address(0xBEEF).code.length == 0, "target unexpectedly has code");
        require(callbackReportedSuccess && !stateChangeObserved, "unexpected state change");
        confirmed = true;
    }
}

