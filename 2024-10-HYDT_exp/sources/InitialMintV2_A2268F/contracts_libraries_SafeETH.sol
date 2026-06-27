// SPDX-License-Identifier: GNU GPLv3

pragma solidity ^0.8.0;

library SafeETH {

    function safeTransferETH(address to, uint256 value) internal {
        (bool success, ) = to.call{value: value}(new bytes(0));

        require(success, "SafeETH::safeTransferETH: ETH transfer failed");
    }
}