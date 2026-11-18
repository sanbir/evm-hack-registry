// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;
import "forge-std/Test.sol";
import {Exploit} from "./37920-h-06-minttoken-mintwithbudget-and-forge-in-the-traitforgenft.sol";

contract Finding37920Test is Test {
    function test_exploit_mint_budget_and_forge_revert() public {
        Exploit e = new Exploit();
        e.run();
        assertEq(e.nft().failedMints(), 3, "three failures");
        assertEq(e.nft().currentGeneration(), 1, "stuck generation");
        assertFalse(e.entropy().initialized(), "not initialized");
        assertEq(e.entropy().allowedCaller(), address(e.nft()), "caller was set");
    }

    function test_control_allowed_caller_opens_the_generation() public {
        Exploit e = new Exploit();
        e.run();
        e.nft().setUseFix(true);
        assertTrue(e.nft().tryMint(), "mint works");
        assertTrue(e.entropy().fixedInitialized(), "indices set");
        assertEq(e.nft().currentGeneration(), 2, "generation advanced");
    }
}
