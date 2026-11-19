// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {Exploit, ERC20Handler, BridgeFixed} from "./50982-lack-of-refund-mechanism-for-overpayment-halborn-chiliz-brid.sol";

contract OverpayLockTest is Test {
    address internal constant SINK = 0x000000000000000000000000000000000000D00d;

    receive() external payable {}

    function test_fiveEtherDepositLocksFour() public {
        vm.deal(address(this), 5 ether);
        Exploit exp = new Exploit();
        exp.run{value: 5 ether}();

        assertEq(address(exp.handler()).balance, 4 ether, "4 ether stuck in the ERC20 handler");
        assertEq(address(exp.bridge()).balance, 1 ether, "bridge kept only the fee");
        assertEq(exp.locked(), 4 ether, "recorded lock");
        assertEq(exp.marker().balanceOf(SINK), 4 ether, "marker shows 4 ether");
    }

    function test_control_refundsTheFourEther() public {
        vm.deal(address(this), 5 ether);
        ERC20Handler handler = new ERC20Handler();
        BridgeFixed bridge = new BridgeFixed(handler);
        uint256 beforeBal = address(this).balance;

        bridge.deposit{value: 5 ether}(111, keccak256("ERC20"), "");

        assertEq(address(handler).balance, 0, "handler does not keep the overpay");
        assertEq(address(bridge).balance, 1 ether, "only the 1 ether fee stays");
        assertEq(address(this).balance, beforeBal - 1 ether, "4 ether was refunded");
    }
}
