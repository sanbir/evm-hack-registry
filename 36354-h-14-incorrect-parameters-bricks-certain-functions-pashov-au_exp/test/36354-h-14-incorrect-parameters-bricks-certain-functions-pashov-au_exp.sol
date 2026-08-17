// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.27;

import "forge-std/Test.sol";
import {Exploit, Pool, MarkerToken} from "./36354-h-14-incorrect-parameters-bricks-certain-functions-pashov-au.sol";

// Lucidly H-14 (finding 36354): setWeightBands and setRamp declare their array
// parameters as fixed-length uint256[MAX_NUM_TOKENS] (=32). The caller is forced
// to pass 32 elements, but the loop reverts with Pool__IndexOutOfBounds once
// t == _numTokens (< 32 for any normal pool). Both admin setters are therefore
// permanently bricked. Deploy a 3-token pool, call both with valid 32-length
// arrays, prove each reverts, and record the 2 bricked functions to SINK.
contract Finding36354Test is Test {
    address internal constant SINK = 0x000000000000000000000000000000000000D00d;

    function test_exploit_incorrectParams_bricksSetters() public {
        Exploit e = new Exploit();
        e.run();

        emit log_named_uint("numTokens", e.pool().numTokens());
        emit log_named_uint("maxNumTokens", e.pool().maxNumTokens());
        emit log_named_uint("bricked functions -> SINK", e.brickedFunctions());

        assertTrue(e.setWeightBandsBricked(), "setWeightBands must be bricked (revert)");
        assertTrue(e.setRampBricked(), "setRamp must be bricked (revert)");
        assertEq(e.pool().numTokens(), 3, "normal pool uses 3 tokens");
        assertEq(e.pool().amplification(), 0, "amplification never configurable");
        assertEq(e.brickedFunctions(), 2, "two admin functions permanently unusable");
        assertEq(e.marker().balanceOf(SINK), 2e18, "bricked-function magnitude recorded to SINK");
    }
}
