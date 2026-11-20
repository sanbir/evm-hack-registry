// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import "forge-std/Test.sol";
import {Exploit, Asset, VaultFixed} from "./62399-loglab-15-last-withdrawer-could-give-next-depositor-0-shares.sol";

contract Finding62399Test is Test {
    address internal constant ATTACKER = 0x1111111111111111111111111111111111111111;
    address internal constant SINK = 0x000000000000000000000000000000000000D00d;

    function test_exploit_last_claim_pays_idle() public {
        Exploit e = new Exploit();
        e.run();
        assertEq(e.asset().balanceOf(ATTACKER), 150 ether, "paid 150");
        assertEq(e.marker().balanceOf(SINK), 50 ether, "50 extra");
    }

    function test_control_pays_the_request_only() public {
        Asset asset = new Asset();
        VaultFixed vault = new VaultFixed(asset);
        asset.mint(address(vault), 150 ether);
        uint256 paid = vault.claim(ATTACKER);
        assertEq(paid, 100 ether, "requested 100");
        assertEq(asset.balanceOf(address(vault)), 50 ether, "idle stays");
    }
}
