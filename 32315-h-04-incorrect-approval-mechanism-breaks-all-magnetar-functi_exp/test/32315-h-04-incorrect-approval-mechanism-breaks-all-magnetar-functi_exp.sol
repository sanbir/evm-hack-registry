// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "./32315-h-04-incorrect-approval-mechanism-breaks-all-magnetar-functi.sol";

contract IncorrectApprovalBreaksMagnetarTest is Test {
    function test_magnetar_yb_approval_insufficient_for_pearlmit_sgl() public {
        Exploit exp = new Exploit();
        exp.run();

        assertEq(exp.sgl().balanceOf(address(exp)), exp.AMOUNT(), "control path eventually credits");
    }

    function test_buggy_path_alone_fails() public {
        MockERC20 asset = new MockERC20();
        MockYieldBox yb = new MockYieldBox();
        Pearlmit pearlmit = new Pearlmit();
        Singularity sgl = new Singularity(pearlmit, asset);
        Magnetar magnetar = new Magnetar(yb, pearlmit);
        asset.mint(address(magnetar), 10 ether);

        bool ok = magnetar.depositYBLendSGL(sgl, address(this), 10 ether);
        assertFalse(ok, "buggy path fails");
        assertEq(sgl.balanceOf(address(this)), 0, "no credit");
    }
}
