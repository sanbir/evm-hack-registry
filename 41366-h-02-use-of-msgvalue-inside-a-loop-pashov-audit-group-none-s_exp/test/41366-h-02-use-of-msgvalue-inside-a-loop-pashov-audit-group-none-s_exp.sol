// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import "forge-std/Test.sol";
import {
    Exploit,
    FeeSink,
    GachaMachineFixed
} from "./41366-h-02-use-of-msgvalue-inside-a-loop-pashov-audit-group-none-s.sol";

contract Finding41366Test is Test {
    function test_exploit_one_payment_two_credits() public {
        Exploit e = new Exploit();
        e.run{value: 2 ether}();

        assertEq(e.machine().credits(address(e)), 2, "two tickets for one payment");
        assertEq(address(e.fee()).balance, 2 ether, "fee received 2 ETH");
        assertEq(address(e.machine()).balance, 0, "machine emptied");
        assertEq(e.machine().escrowOf(e.VICTIM()), 1 ether, "victim still booked for 1 ETH");
        assertEq(e.machine().accounted(), 2 ether, "msg.value added twice");
        emit log_named_uint("credits", e.machine().credits(address(e)));
        emit log_named_uint("fee_wei", address(e.fee()).balance);
        emit log_named_uint("accounted_wei", e.machine().accounted());
        emit log_named_uint("victim_escrow_wei", e.machine().escrowOf(e.VICTIM()));
        emit log_named_uint("machine_balance_wei", address(e.machine()).balance);
    }

    function test_control_counts_msg_value_once() public {
        FeeSink fee = new FeeSink();
        GachaMachineFixed fixedMachine = new GachaMachineFixed(address(fee));
        fixedMachine.setController(address(this));

        address victim = address(0x2222222222222222222222222222222222222222);
        fixedMachine.escrowFor{value: 1 ether}(victim);

        GachaMachineFixed.MintData[] memory rows = new GachaMachineFixed.MintData[](2);
        rows[0] = GachaMachineFixed.MintData({collectionId: 1, spins: 1, minter: address(this)});
        rows[1] = GachaMachineFixed.MintData({collectionId: 1, spins: 1, minter: address(this)});
        fixedMachine.batchCommitToMint{value: 1 ether}(rows);

        assertEq(fixedMachine.credits(address(this)), 1, "one credit for 1 ETH");
        assertEq(address(fee).balance, 1 ether, "fee received the payment once");
        assertEq(fixedMachine.accounted(), 1 ether, "msg.value counted once");
        assertEq(address(fixedMachine).balance, 1 ether, "victim escrow remains");
        assertEq(fixedMachine.escrowOf(victim), 1 ether, "victim booking intact");
    }
}
