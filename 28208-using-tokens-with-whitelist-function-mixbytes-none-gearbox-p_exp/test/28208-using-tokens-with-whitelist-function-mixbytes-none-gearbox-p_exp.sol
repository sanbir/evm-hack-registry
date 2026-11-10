// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import "forge-std/Test.sol";
import "forge-std/console2.sol";
import {Exploit} from "./28208-using-tokens-with-whitelist-function-mixbytes-none-gearbox-p.sol";

contract Finding28208Test is Test {
    function test_whitelist_tokens_stay_stuck_and_liquidator_is_charged() public {
        Exploit e = new Exploit();
        e.run();

        assertEq(e.stuck(), 1_000 ether, "1000 whitelist tokens stuck");
        assertEq(e.wl().balanceOf(address(e.wlAccount())), 1_000 ether, "credit account still holds them");
        assertEq(e.wl().balanceOf(address(e)), 0, "liquidator received none");
        assertEq(e.charged(), 1_000 ether, "totalValue still 1000");
        assertEq(e.underlying().balanceOf(address(e.manager())), 2_000 ether, "both quotes were pulled");

        assertEq(e.controlReceived(), 1_000 ether - 1, "plain token arrived");
        assertEq(e.plain().balanceOf(address(e.plainAccount())), 1, "plain dust left behind");

        console2.log("stuck WUSD wei", e.stuck());
        console2.log("charged DAI wei", e.charged());
        console2.log("control PUSD wei", e.controlReceived());
    }

    function test_control_plain_token_transfer_succeeds() public {
        Exploit e = new Exploit();
        e.runControl();
        assertEq(e.controlReceived(), 1_000 ether - 1, "recipient got the tokens");
        assertEq(e.plain().balanceOf(address(e.plainAccount())), 1, "dust");
        assertEq(e.underlying().balanceOf(address(e.manager())), 1_000 ether, "payment matches a successful transfer");
        console2.log("control-only received PUSD wei", e.controlReceived());
    }
}
