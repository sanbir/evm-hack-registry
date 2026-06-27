// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

contract MulticallWithETH {
    struct Call {
        address target;
        bytes callData;
        uint256 value;
        bool allowFailure;
    }

    struct Result {
        bool success;
        bytes returnData;
    }

    function aggregate(Call[] calldata calls) external payable returns (Result[] memory returnData) {
        uint256 length = calls.length;
        returnData = new Result[](length);
        uint256 totalSent;

        for (uint256 i = 0; i < length; i++) {
            totalSent += calls[i].value;

            (bool success, bytes memory ret) = calls[i].target.call{value: calls[i].value}(calls[i].callData);

            if (!success && !calls[i].allowFailure) {
                revert(string(abi.encodePacked("Call failed at index ", uint2str(i))));
            }

            returnData[i] = Result(success, ret);
        }

        require(totalSent <= msg.value, "Insufficient msg.value");
    }

    function viewAggregate(Call[] calldata calls) external view returns (Result[] memory returnData) {
        uint256 length = calls.length;
        returnData = new Result[](length);

        for (uint256 i = 0; i < length; i++) {
            (bool success, bytes memory ret) = calls[i].target.staticcall(calls[i].callData);

            returnData[i] = Result(success, ret);
        }
    }

    // 帮助函数：uint -> string
    function uint2str(uint256 _i) internal pure returns (string memory str) {
        if (_i == 0) return "0";
        uint256 j = _i;
        uint256 length;

        while (j != 0) {
            length++;
            j /= 10;
        }

        bytes memory bstr = new bytes(length);
        uint256 k = length - 1;

        while (_i != 0) {
            bstr[k--] = bytes1(uint8(48 + _i % 10));
            _i /= 10;
        }

        str = string(bstr);
    }

    function getBalances(address[] calldata addresses) external view returns (uint256[] memory balances) {
        uint256 length = addresses.length;
        balances = new uint256[](length);

        for (uint256 i = 0; i < length; i++) {
            balances[i] = addresses[i].balance;
        }
    }
}