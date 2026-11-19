// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

// AuditVault 50982 - Chiliz Bridge.deposit.
// msg.value above the fee is transferred to the ERC20 handler. The handler's
// deposit() does not refund it. A 5 ether deposit with a 1 ether fee locks 4 ether.

contract ERC20Handler {
    receive() external payable {}

    function deposit(bytes32, uint8, uint64, address, bytes calldata) external {
        // ERC20 deposit does not refund the native value Bridge forwarded.
    }
}

contract StuckETH {
    string public symbol = "STUCK-ETH";
    uint8 public constant decimals = 18;
    mapping(address => uint256) public balanceOf;

    function mint(address to, uint256 amt) external {
        balanceOf[to] += amt;
    }
}

contract Bridge {
    uint256 public constant FEE = 1 ether;
    ERC20Handler public handler;

    constructor(ERC20Handler h) {
        handler = h;
    }

    function deposit(uint8 destinationChainID, bytes32 resourceID, bytes calldata data) external payable {
        require(msg.value >= FEE, "invalid value"); // S:fee
        uint256 valueToSend = msg.value - FEE; // S:excess
        if (valueToSend > 0) { // S:if
            // @> VULN: excess native value is forwarded and never refunded
            payable(address(handler)).transfer(valueToSend); // S:vuln
        }
        handler.deposit(resourceID, destinationChainID, 1, msg.sender, data); // S:dep
    }
}

contract BridgeFixed {
    uint256 public constant FEE = 1 ether;
    ERC20Handler public handler;

    constructor(ERC20Handler h) {
        handler = h;
    }

    function deposit(uint8 destinationChainID, bytes32 resourceID, bytes calldata data) external payable {
        require(msg.value >= FEE, "invalid value");
        uint256 refund = msg.value - FEE;
        if (refund > 0) {
            payable(msg.sender).transfer(refund);
        }
        handler.deposit(resourceID, destinationChainID, 1, msg.sender, data);
    }
}

contract Exploit {
    address internal constant SINK = 0x000000000000000000000000000000000000D00d;

    ERC20Handler public handler;
    Bridge public bridge;
    StuckETH public marker;
    uint256 public locked;

    function run() external payable {
        require(msg.value == 5 ether, "value"); // S:value
        handler = new ERC20Handler();
        bridge = new Bridge(handler);
        marker = new StuckETH();
        bytes32 resourceID = keccak256("ERC20"); // S:rid
        bridge.deposit{value: msg.value}(111, resourceID, ""); // S:call
        locked = address(handler).balance; // S:locked
        marker.mint(SINK, locked); // S:mark
    }

    receive() external payable {}
}
