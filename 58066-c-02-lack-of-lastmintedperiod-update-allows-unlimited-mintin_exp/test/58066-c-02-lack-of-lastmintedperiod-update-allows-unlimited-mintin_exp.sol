// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "./58066-c-02-lack-of-lastmintedperiod-update-allows-unlimited-mintin.sol";

/* KittenSwap C-02 — missing lastMintedPeriod update → unlimited Kitten mint (Pashov 2025-06) */
contract PoC_58066 is Test {
    function test_unlimitedMinting() public {
        Exploit e = new Exploit();
        e.run();

        assertEq(e.minter().lastMintedPeriod(), 0, "lastMintedPeriod never updated");
        assertEq(e.kitten().totalSupply(), e.minter().weekly() * 10, "10x weekly minted");
        assertEq(e.mintedExtra(), e.minter().weekly() * 9, "9 extra weeks of emissions");
    }

    function test_control_wouldStopIfUpdated() public {
        // Sanity: if lastMintedPeriod were set after first mint, further mints stop.
        // We can't patch Minter in-place; this documents the intended fix behaviour
        // by checking the guard condition algebraically.
        uint256 lastMintedPeriod = 0;
        uint256 currentPeriod = 1;
        assertTrue(currentPeriod > lastMintedPeriod, "first mint allowed");
        lastMintedPeriod = currentPeriod; // the missing line
        assertFalse(currentPeriod > lastMintedPeriod, "second mint blocked after fix");
    }
}
