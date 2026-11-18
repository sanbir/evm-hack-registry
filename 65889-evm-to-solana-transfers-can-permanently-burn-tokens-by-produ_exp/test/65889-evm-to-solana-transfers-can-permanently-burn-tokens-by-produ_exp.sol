// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import "forge-std/Test.sol";
import {Exploit} from "./65889-evm-to-solana-transfers-can-permanently-burn-tokens-by-produ.sol";

contract Finding65889Test is Test {
    function test_exploit_u64_overflow_burns_with_no_solana_mint() public {
        Exploit e = new Exploit();
        uint256 amount = uint256(type(uint64).max) + 1;
        e.run();

        assertEq(e.accepted(), false, "decoder rejected");
        assertEq(e.solana().minted(), 0, "no mint");
        assertEq(e.ds().balanceOf(address(e)), 0, "user burned");
        assertEq(e.ds().burned(), amount, "burned amount");
        assertEq(e.ds().balanceOf(address(0x000000000000000000000000000000000000dEaD)), amount, "dead sink");
    }

    function test_control_value_inside_u64_mints_on_solana() public {
        Exploit e = new Exploit();
        // The overflow mint filled the user. Give them a small extra balance and bridge that.
        e.ds().mint(address(e), 1000);
        bool accepted = e.bridgeSmall(1000);
        assertTrue(accepted, "u64 value decodes");
        assertEq(e.solana().minted(), 1000, "solana minted the burned amount");
    }
}
