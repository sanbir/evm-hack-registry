// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import { Test, console2 } from "forge-std/Test.sol";
import { FlatBytesLib } from "../src/BytesLib.sol";

contract GasTest is Test {
    using FlatBytesLib for FlatBytesLib.Bytes;

    bytes _data;
    FlatBytesLib.Bytes _bytesData;

    function setUp() public { }

    function gasDiff(bytes memory d) public {
        uint256 gasSplit = gasleft();
        _bytesData.store(d);
        gasSplit = gasSplit - gasleft();

        uint256 gasNormal = gasleft();
        _data = d;
        gasNormal = gasNormal - gasleft();

        console2.log("len", d.length);
        console2.log("gasSplit", gasSplit);
        console2.log("gasNormal", gasNormal);
        console2.log("diff", gasSplit - gasNormal);
    }

    function testGas_Short() public {
        bytes memory d =
            hex"424141414141414141414141414141414141414141414141414141414141414141414143";
        gasDiff(d);
    }

    function testGas_Average() public {
        bytes memory d =
            hex"424141414141414141414141414141414141414141414141414141414141414141414143424141414141414141414141414141414141414141414141414141414141414141414143";
        gasDiff(d);
    }

    function testGas_Long() public {
        bytes memory d;
        for (uint256 i = 0; i < 5; i++) {
            d = abi.encodePacked(
                d, hex"424141414141414141414141414141414141414141414141414141414141414141414143"
            );
        }
        gasDiff(d);
    }
}
