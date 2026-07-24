// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "./64141-h-02-unoptimized-subset-matches-counting-implementation-will.sol";

contract MegapotSubsetGasDosTest is Test {
    function test_exploit() public {
        Exploit e = new Exploit();
        e.run();

        assertGt(e.extrapolatedGas(), e.BASE_TX_GAS(), "exceeds Base 25M");
        assertGt(e.sampleGas(), 0, "sample measured");
    }

    /// @dev Optional control: with bonusballMax=1 the sample is cheap (still measures).
    function test_smallBonusIsCheaper() public {
        JackpotSettlement s = new JackpotSettlement();
        s.configure(1, 5);
        uint256 g1 = s.settleDrawing(0x3E0, 1);
        s.configure(8, 5);
        uint256 g8 = s.settleDrawing(0x3E0, 1);
        assertGt(g8, g1, "gas scales with bonusballMax");
    }
}
