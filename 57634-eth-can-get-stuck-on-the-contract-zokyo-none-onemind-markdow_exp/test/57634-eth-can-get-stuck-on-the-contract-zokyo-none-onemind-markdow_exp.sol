// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {
    Exploit,
    FeePayerFixed,
    RejectEth
} from "./57634-eth-can-get-stuck-on-the-contract-zokyo-none-onemind-markdow.sol";

contract Finding57634Test is Test {
    function test_exploit_failed_eth_transfer_sticks_fee() public {
        Exploit e = new Exploit();
        e.run{value: 1 ether}();
        assertEq(e.stuck(), 1 ether, "1 ether stuck");
        assertEq(e.mints(), 1, "mint continued");
        assertEq(address(e.feePayer()).balance, 1 ether, "fee payer holds it");
        assertEq(address(e.rejecter()).balance, 0, "receiver got nothing");
    }

    function test_control_failed_transfer_reverts_and_keeps_eth() public {
        RejectEth rejecter = new RejectEth();
        FeePayerFixed payer = new FeePayerFixed(rejecter);
        uint256 before = address(this).balance;
        vm.expectRevert(bytes("fee transfer"));
        payer.handleMintFee{value: 1 ether}();
        assertEq(address(payer).balance, 0, "nothing stuck");
        assertEq(payer.mintCount(), 0, "mint did not continue");
        assertEq(address(this).balance, before, "caller refunded");
    }
}
