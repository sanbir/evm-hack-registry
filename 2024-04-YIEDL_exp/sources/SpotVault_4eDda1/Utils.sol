//// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;
import "EnumerableSet.sol";

abstract contract Utils {
    function absSlippage(uint256 start, uint256 end, uint256 unit) internal pure returns (uint256) {
        uint256 diff = start > end ? start - end : end - start;
        return (diff * unit) / start;
    }
}
