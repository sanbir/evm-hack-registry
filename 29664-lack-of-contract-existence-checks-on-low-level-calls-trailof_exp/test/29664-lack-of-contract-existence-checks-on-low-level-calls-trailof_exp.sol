// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;
import "forge-std/Test.sol";
import {Exploit, PositionToken, NestedWallet, HyVM} from "./29664-lack-of-contract-existence-checks-on-low-level-calls-trailof.sol";

contract Finding29664Test is Test {
    function test_exploit_empty_delegatecall_seizes_position() public {
        Exploit e = new Exploit();
        e.run();
        assertEq(e.token().balanceOf(address(e)), 1000 ether, "seized");
        assertEq(e.wallet().collateral(), 1000 ether, "no top-up");
        assertTrue(e.wallet().lastSuccess(), "reported success");
        assertTrue(e.wallet().seized(), "liquidated");
        assertEq(e.DESTROYED_HYVM().code.length, 0, "no code");
    }

    function test_control_codesize_check_saves_the_position() public {
        PositionToken token = new PositionToken();
        NestedWallet w = new NestedWallet(token);
        token.mint(address(w), 1000 ether);
        HyVM hy = new HyVM();
        w.executeChecked(address(hy), abi.encodeWithSignature("topUp(uint256)", 500 ether));
        assertEq(w.collateral(), 1500 ether, "topped up");
        vm.expectRevert(bytes("healthy"));
        w.liquidate();
        vm.expectRevert(bytes("no code"));
        w.executeChecked(address(0xBEEF), abi.encodeWithSignature("topUp(uint256)", 1));
        assertEq(token.balanceOf(address(w)), 1000 ether, "still held");
    }
}
