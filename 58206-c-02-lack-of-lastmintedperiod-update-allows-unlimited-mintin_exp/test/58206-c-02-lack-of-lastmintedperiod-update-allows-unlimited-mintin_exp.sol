// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;
import "forge-std/Test.sol";
import {Exploit, Minter, Kitten} from "./58206-c-02-lack-of-lastmintedperiod-update-allows-unlimited-mintin.sol";
contract Finding58206Test is Test {
    function test_unlimitedMinting() public {
        Exploit e = new Exploit();
        e.run();
        assertEq(e.totalMinted(), 10 * 200 ether, "10 periods minted from 1");
        assertEq(e.excessMinted(), 9 * 200 ether, "9 periods over-minted");
    }
}
