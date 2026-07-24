// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "./48954-h-15-the-last-borrowed-asset-will-not-be-collateralized-and.sol";

contract PoC_48954 is Test {
    function test_lastAssetUncollateralized() public {
        Exploit e = new Exploit();
        e.run();
    }
}
