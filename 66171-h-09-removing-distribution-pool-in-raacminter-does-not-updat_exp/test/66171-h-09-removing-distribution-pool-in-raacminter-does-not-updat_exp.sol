// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import "forge-std/Test.sol";
import {Exploit, ERC20, Pool, Minter} from
    "./66171-h-09-removing-distribution-pool-in-raacminter-does-not-updat.sol";

contract Finding66171Test is Test {
    function test_exploit_removed_weight_stays_in_total() public {
        Exploit e = new Exploit();
        e.run();
        assertEq(e.minter().totalWeight(), 100, "stale total");
        assertEq(e.token().balanceOf(address(e.poolA())), 50 ether, "A underpaid");
        assertEq(e.token().balanceOf(address(e.minter())), 50 ether, "stuck");
    }

    function test_control_subtracts_weight_before_delete() public {
        ERC20 token = new ERC20();
        Pool a = new Pool();
        Pool b = new Pool();
        Minter m = new Minter(token, address(this), true);
        m.addPool(address(a), 50);
        m.addPool(address(b), 50);
        token.mint(address(m), 100 ether);
        m.removeDistributionPool(address(b));
        assertEq(m.totalWeight(), 50, "weight reduced");
        m.processMintedRewards(100 ether);
        assertEq(token.balanceOf(address(a)), 100 ether, "A paid in full");
        assertEq(token.balanceOf(address(m)), 0, "nothing stuck");
    }
}
