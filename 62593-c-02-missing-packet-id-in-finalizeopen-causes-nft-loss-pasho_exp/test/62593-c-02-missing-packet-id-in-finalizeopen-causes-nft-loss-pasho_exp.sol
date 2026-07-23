// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "./62593-c-02-missing-packet-id-in-finalizeopen-causes-nft-loss-pasho.sol";

contract PacketIdTest is Test {
    function test_exploit() public {
        Exploit e = new Exploit();
        e.run();
    }
}
