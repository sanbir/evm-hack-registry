// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import "forge-std/Test.sol";
import {Exploit, Token, BinPoolFixed, Joiner} from
    "./46983-loss-of-input-tokens-due-to-incorrect-rounding-ottersec-none.sol";

contract Finding46983Test is Test {
    function test_exploit_zero_shares_take_the_deposit() public {
        Exploit e = new Exploit();
        e.run();

        assertEq(e.taken(), 1101 ether, "withdrew 1101");
        assertEq(e.tokenX().balanceOf(address(e)), 1101 ether, "attacker holds X");
        assertEq(e.tokenX().balanceOf(address(e.joiner())), 0, "joiner lost 100");
        assertEq(e.pool().lastShares(), 0, "rounded to 0");
        assertEq(e.pool().reserveX(), 0, "bin emptied");
    }

    function test_control_zero_share_mint_keeps_the_deposit() public {
        Token x = new Token("X");
        Token y = new Token("Y");
        BinPoolFixed pool = new BinPoolFixed(x, y);
        Joiner joiner = new Joiner();

        x.mint(address(this), 1001 ether);
        y.mint(address(this), 1001 ether);
        x.approve(address(pool), type(uint256).max);
        y.approve(address(pool), type(uint256).max);
        pool.mint(1 ether, 1 ether);
        pool.donate(1000 ether, 1000 ether);

        x.mint(address(joiner), 100 ether);
        joiner.approve(x, address(pool));
        uint256 shares = joiner.joinFixed(pool, 100 ether);

        assertEq(shares, 0, "still rounds to 0");
        assertEq(x.balanceOf(address(joiner)), 100 ether, "deposit returned");
        assertEq(pool.reserveX(), 1001 ether, "donation only");
        assertEq(pool.sharesOf(address(joiner)), 0, "no shares");
    }
}
