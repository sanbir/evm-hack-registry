// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "./36914-h-02-incorrectly-assigned-decimal1-parameter-upon-decoding-c.sol";

contract BasinDecimal1DecodeTest is Test {
    function test_exploit_wrongDecimal1OvervaluesToken1() public {
        Exploit e = new Exploit();
        e.run();
        assertEq(e.dec1Decoded(), 0, "decimal1 left at 0");
        assertEq(e.correctLp(), 2 ether, "correct LP");
        assertGt(e.wrongLp(), e.correctLp(), "overvaluation");
        assertTrue(e.scaledBlewOrWrong(), "severe mis-scale");
    }

    function test_control_fixedDecoderCoercesDecimal1() public {
        Stable2Fixed f = new Stable2Fixed();
        uint256[] memory d = f.decodeWellData(abi.encode(uint256(6), uint256(0)));
        assertEq(d[0], 6);
        assertEq(d[1], 18);
    }
}
