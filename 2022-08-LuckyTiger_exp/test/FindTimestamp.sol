// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.13;
import "forge-std/Test.sol";

contract FindTimestamp is Test {
    function testFind() public {
        vm.createSelectFork("http://127.0.0.1:8545", 15_403_430);
        console.log("block.difficulty:", block.difficulty);
        console.log("block.timestamp:", block.timestamp);
        
        // Try timestamps around the actual block timestamp
        uint256 base = 1661351167;
        for (uint256 i = 0; i < 1000; i++) {
            uint256 ts = base + i;
            if (uint256(keccak256(abi.encodePacked(block.difficulty, ts))) % 2 == 1) {
                console.log("Lucky timestamp offset:", i);
                console.log("Lucky timestamp:", ts);
                break;
            }
        }
    }
}
