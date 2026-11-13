// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import "forge-std/Test.sol";
import {
    Exploit,
    LinkToken,
    OracleFixed
} from "./19293-users-can-form-malicious-requests-to-steal-tokens-from-oracl.sol";

contract Finding19293Test is Test {
    function test_crafted_request_pulls_200e18_from_the_oracle() public {
        Exploit e = new Exploit();
        e.run();
        assertEq(e.stolen(), 200 ether, "attacker received 200e18");
        assertEq(e.link().balanceOf(address(e)), 200 ether, "exploit holds the LINK");
        assertEq(e.link().balanceOf(address(e.oracle())), 0, "oracle lost 200e18");
    }

    function test_control_rejects_link_callback() public {
        LinkToken link = new LinkToken();
        OracleFixed oracle = new OracleFixed(link);
        link.mint(address(oracle), 200 ether);

        bool accepted;
        try oracle.request(address(link), link.transfer.selector, address(this)) {
            accepted = true;
        } catch {
            accepted = false;
        }
        assertFalse(accepted, "LINK callback is rejected");
        assertEq(link.balanceOf(address(oracle)), 200 ether, "oracle keeps 200e18");
        assertEq(link.balanceOf(address(this)), 0, "caller received nothing");
    }
}
