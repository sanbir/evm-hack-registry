// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import { Test } from "forge-std/Test.sol";
import { FlatBytesLib } from "../src/BytesLib.sol";

contract BytesLibTest is Test {
    using FlatBytesLib for FlatBytesLib.Bytes;
    using FlatBytesLib for mapping(address => FlatBytesLib.Bytes);

    FlatBytesLib.Bytes data;
    mapping(address account => FlatBytesLib.Bytes) internal dataMapping;

    function setUp() public { }

    function testStore() public {
        bytes memory _data =
            hex"424141414141414141414141414141414141414141414141414141414141414141414143";

        vm.record();
        data.store(_data);
        (, bytes32[] memory writes) = vm.accesses(address(this));

        bytes memory _storedData = data.load();

        assertEq(_storedData, _data);

        bytes32 dataSlot;
        assembly {
            dataSlot := data.slot
        }
        assertEq(writes[0], dataSlot);
    }

    function testStore_WhenUsing_Mapping() public {
        bytes memory _data =
            hex"424141414141414141414141414141414141414141414141414141414141414141414143";

        vm.record();
        dataMapping[address(2)].store(_data);
        (, bytes32[] memory writes) = vm.accesses(address(this));

        bytes memory _storedData = dataMapping[address(2)].load();

        assertEq(_storedData, _data);

        FlatBytesLib.Bytes storage bytesStorage = dataMapping[address(2)];
        bytes32 dataSlot;
        assembly {
            dataSlot := bytesStorage.slot
        }
        assertEq(writes[0], dataSlot);
    }

    function testClear() public {
        testStore();
        data.clear();

        bytes memory _d = data.load();
        assertEq(_d.length, 0);
    }
}
