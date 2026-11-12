// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {
    Exploit,
    Jetton,
    Wallet,
    YTMinterFixed
} from "./57083-an-attacker-can-prevent-the-redemption-of-yt-and-pt-tokens-f.sol";

contract Finding57083Test is Test {
    function test_attacker_force_settles_one_and_the_follow_up_reverts() public {
        Exploit e = new Exploit();
        e.run();

        assertEq(e.syToAlice(), 1, "Alice was paid 1 SY");
        assertEq(e.ptBack(), e.N() - 1, "N-1 PT was pushed back");
        assertTrue(e.followUpReverted(), "redeem of N reverts");
        assertEq(e.sy().balanceOf(address(e.alice())), 1, "SY balance stays 1");
        assertEq(e.yt().balanceOf(address(e.alice())), e.N(), "YT still unredeemed");
        assertEq(e.minter().syPaid(), 1, "minter paid 1");
    }

    function test_control_sender_in_the_key_pays_N() public {
        Jetton pt = new Jetton("PT");
        Jetton yt = new Jetton("YT");
        Jetton sy = new Jetton("SY");
        YTMinterFixed minter = new YTMinterFixed(pt, yt, sy);
        Wallet alice = new Wallet();
        Wallet eve = new Wallet();
        uint256 n = 1_000_000_000;

        pt.mint(address(alice), n);
        yt.mint(address(alice), n);
        yt.mint(address(eve), 1);
        alice.approve(pt, address(minter), n);
        alice.approve(yt, address(minter), n);
        eve.approve(yt, address(minter), 1);

        alice.registerFixed(minter, n, 0);
        eve.registerForFixed(minter, address(alice), 0, 1);
        alice.finishFixed(minter, n);

        assertEq(sy.balanceOf(address(alice)), n, "control pays N SY");
        assertEq(pt.balanceOf(address(alice)), 0, "control consumes the PT");
        assertEq(minter.syPaid(), n, "minter paid N");
        (uint256 evePt, uint256 eveYt) = minter.balancesOf(address(alice), address(eve));
        assertEq(evePt, 0, "eve key is not alice's PT");
        assertEq(eveYt, 1, "eve's 1 YT sits on her own deposit");
    }
}
