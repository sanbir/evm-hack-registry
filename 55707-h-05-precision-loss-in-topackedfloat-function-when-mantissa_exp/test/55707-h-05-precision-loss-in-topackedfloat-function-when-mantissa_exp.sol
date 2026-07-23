// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "./55707-h-05-precision-loss-in-topackedfloat-function-when-mantissa.sol";

contract H05Exp is Test {
    function test_h05_topackedfloat_precision_loss() public {
        Exploit e = new Exploit();
        e.run();

        VulnerableFloat128 lib = e.lib();
        int256 man = int256(uint256(1) << 235);
        int256 expo = -51;
        packedFloat float = lib.toPackedFloat(man, expo);
        (int256 manDecode, int256 expDecode) = lib.decode(float);
        assertEq(lib.findNumberOfDigits(uint256(manDecode)), 38);
        assertEq(expDecode, -18);

        int256 recovered = manDecode;
        for (int256 i = 0; i < expDecode - expo; i++) {
            recovered *= 10;
        }
        assertLt(recovered, man, "precision permanently lost");
        assertEq(man - recovered, 608871777363092441300193790394368);
    }
}
