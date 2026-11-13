// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import "forge-std/Test.sol";
import "forge-std/console2.sol";
import {Exploit} from "./53287-h-04-stuck-eth-in-giganamenft-contract-pashov-audit-group-no.sol";

contract Finding53287Test is Test {
    function test_mint_fee_stays_in_the_nft_and_control_withdraws() public {
        Exploit e = new Exploit();
        e.run{value: 2 ether}();

        assertEq(e.stuck(), e.FEE(), "stuck");
        assertEq(e.rescued(), e.FEE(), "rescued");
        assertEq(e.fixedLeft(), 0, "cleared");

        console2.log("stuck eth");
        console2.log(e.stuck());
        console2.log("rescued eth");
        console2.log(e.rescued());
        console2.log("control left");
        console2.log(e.fixedLeft());
    }
}
