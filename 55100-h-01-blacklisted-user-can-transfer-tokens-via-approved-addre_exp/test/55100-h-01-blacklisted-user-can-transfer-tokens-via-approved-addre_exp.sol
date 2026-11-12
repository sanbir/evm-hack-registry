// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {
    BeraBitcoin,
    BeraBitcoinFixed,
    Exploit,
    Holder
} from "./55100-h-01-blacklisted-user-can-transfer-tokens-via-approved-addre.sol";

contract Finding55100Test is Test {
    function test_exploit_blacklisted_holder_moves_1000_via_approval() public {
        Exploit e = new Exploit();
        e.run();
        assertEq(e.stolen(), 1000 ether, "1000 moved");
        assertEq(e.token().balanceOf(address(this)), 1000 ether, "caller received 1000");
        assertFalse(e.directMoved(), "direct transfer was blocked");
    }

    function test_control_fixed_transferFrom_blocks_blacklisted_from() public {
        BeraBitcoinFixed token = new BeraBitcoinFixed();
        Holder holder = new Holder();
        token.mint(address(holder), 1000 ether);
        holder.approve(token, address(this), 1000 ether);
        token.setBlacklist(address(holder), true);
        vm.expectRevert(BeraBitcoin.AccountIsBlacklisted.selector);
        token.transferFrom(address(holder), address(this), 1000 ether);
        assertEq(token.balanceOf(address(holder)), 1000 ether, "1000 stayed");
        assertEq(token.balanceOf(address(this)), 0, "caller got nothing");
    }
}
