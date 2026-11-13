// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "forge-std/console2.sol";
import {Exploit, Lido, SelfOwnedStETHBurner} from
    "./28161-possibility-of-taking-burned-shares-mixbytes-none-lido-markd.sol";

contract Finding28161Test is Test {
    function test_uncapped_burn_pays_a_fresh_depositor() public {
        Exploit e = new Exploit();
        vm.deal(address(this), 100_000);
        e.run{value: 100_000}();
        assertEq(e.shareValue(), 122222, "share value");
        assertEq(e.excess(), 22222, "excess");
        assertEq(e.kept(), 22222, "kept");
        console2.log("share value", e.shareValue());
        console2.log("excess kept", e.kept());
    }

    function test_control_four_bps_cap_keeps_the_excess_at_40() public {
        Lido lido = new Lido();
        SelfOwnedStETHBurner burner = new SelfOwnedStETHBurner(address(lido));
        lido.setBurner(address(burner));
        lido.setOracle(address(this));
        lido.seed(address(burner), 200_000);
        burner.seedRequested(200_000);

        vm.deal(address(this), 100_000);
        lido.submit{value: 100_000}();
        uint256 burned = burner.processCapped(0, 0, 0);
        uint256 value = lido.balanceOf(address(this));
        assertEq(burned, 440, "4 bps of 1100000");
        assertEq(value, 100040, "value under the cap");
        assertEq(value - 100_000, 40, "excess is 40 not 22222");
        console2.log("control burned", burned);
        console2.log("control excess", value - 100_000);
    }
}
