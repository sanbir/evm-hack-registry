// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;
import "forge-std/Test.sol";
import {Exploit, Token, Psm} from "./41479-h-5-incoming-redemption-assets-not-being-tracked-when-repurc.sol";
contract Finding41479Test is Test {
    function test_exploit_ra_stuck() public {
        Exploit e = new Exploit();
        e.run();
        assertEq(e.stuck(), 1000 ether, "stuck");
        assertEq(e.ctPaid(), 0, "ct paid 0");
        assertEq(e.psm().archivedRa(), 0, "archive");
    }
    function test_control_lockFrom_archives_ra() public {
        Token ra = new Token("RA");
        Token pa = new Token("PA");
        Token ct = new Token("CT");
        Token ds = new Token("DS");
        Psm psm = new Psm(ra, pa, ct, ds);
        ra.mint(address(this), 1000 ether);
        pa.mint(address(this), 1000 ether);
        ra.approve(address(psm), type(uint256).max);
        pa.approve(address(psm), type(uint256).max);
        psm.deposit(1000 ether);
        psm.redeemWithDsPa(1000 ether);
        psm.repurchaseFixed(1000 ether);
        psm.separateLiquidity();
        uint256 paid = psm.redeemWithCt(1000 ether);
        assertEq(psm.archivedRa(), 1000 ether, "archived");
        assertEq(paid, 1000 ether, "ct paid");
        assertEq(ra.balanceOf(address(psm)), 0, "nothing stuck");
    }
}
