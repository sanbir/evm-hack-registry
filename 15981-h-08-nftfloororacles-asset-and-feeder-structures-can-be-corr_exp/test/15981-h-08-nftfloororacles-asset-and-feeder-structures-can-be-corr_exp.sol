// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "./15981-h-08-nftfloororacles-asset-and-feeder-structures-can-be-corr.sol";

contract PoC_15981 is Test {
    function test_exploit() public {
        Exploit e = new Exploit();
        e.run();
    }
}
