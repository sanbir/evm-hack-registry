// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import "forge-std/Test.sol";
import {
    Exploit,
    SaleToken,
    UniPool
} from "./65000-h-03-its-possible-to-add-liquidity-to-uniswapv3-while-token.sol";

contract Finding65000Test is Test {
    function test_exploit_mints_lp_from_empty_balance() public {
        Exploit e = new Exploit();
        e.run();
        assertEq(e.lpMinted(), e.STOLEN(), "lp minted");
        assertEq(e.attackerBalanceBefore(), 0, "started empty");
        assertEq(e.token().balanceOf(address(e)), e.STOLEN(), "stole inventory");
        assertEq(e.token().balanceOf(address(uint160(0xBEEF))), 0, "inventory empty");
    }

    function test_control_transfer_first_leaves_inventory() public {
        SaleToken token = new SaleToken();
        UniPool pool = new UniPool(token);
        token.migrate();
        uint256 n = 1_000_000 ether;
        token.mint(address(this), n);
        token.transfer(address(pool), n);
        assertEq(token.balanceOf(address(pool)), n, "transferred first");
        assertEq(token.balanceOf(address(this)), 0, "user spent their own tokens");
        assertEq(token.balanceOf(address(uint160(0xBEEF))), 1_000_000 ether, "inventory untouched");
    }
}
