// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

library OptionsBuilder {
    function newOptions() internal pure returns (bytes memory) {
        return abi.encodePacked(uint16(3));
    }

    function addExecutorLzReceiveOption(bytes memory options, uint128, uint128)
        internal
        pure
        returns (bytes memory)
    {
        return options;
    }
}
