// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

/*  Camp send() fee (Quantstamp, July 2025).
    bridgeOut records _originalAmount and accepts exactly that msg.value.
    send() then pays _originalAmount plus a 10% fee from the contract balance.
    The fee was not collected, so it is taken from the next depositor and
    that depositor's bridge can no longer be paid.
*/

contract FeeSink {
    receive() external payable {}
}

contract CampBridge {
    struct Deposit {
        address user;
        uint256 amount;
    }

    Deposit[] public queue;
    FeeSink public immutable feeSink;
    uint256 public constant FEE_BPS = 1_000;

    constructor(FeeSink _feeSink) {
        feeSink = _feeSink;
    }

    function bridgeOut(uint256 originalAmount) external payable {
        require(msg.value == originalAmount, "principal");
        queue.push(Deposit({user: msg.sender, amount: originalAmount}));
    }

    function send(uint256 index) external {
        Deposit memory item = queue[index];
        uint256 fee = item.amount * FEE_BPS / 10_000;
        uint256 total = item.amount + fee;
        require(address(this).balance >= total, "short");
        // @> VULN: the bridge fee is paid from pooled deposits, not from this msg.value
        (bool paidUser,) = item.user.call{value: item.amount}("");
        require(paidUser, "user");
        (bool paidFee,) = address(feeSink).call{value: fee}("");
        require(paidFee, "fee");
    }

    function queuedAmount(uint256 index) external view returns (uint256) {
        return queue[index].amount;
    }

    receive() external payable {}
}

contract CampBridgeFixed {
    struct Deposit {
        address user;
        uint256 amount;
    }

    Deposit[] public queue;
    FeeSink public immutable feeSink;
    uint256 public constant FEE_BPS = 1_000;

    constructor(FeeSink _feeSink) {
        feeSink = _feeSink;
    }

    function bridgeOut(uint256 originalAmount) external payable {
        uint256 fee = originalAmount * FEE_BPS / 10_000;
        require(msg.value == originalAmount + fee, "principal plus fee");
        queue.push(Deposit({user: msg.sender, amount: originalAmount}));
    }

    function send(uint256 index) external {
        Deposit memory item = queue[index];
        uint256 fee = item.amount * FEE_BPS / 10_000;
        (bool paidUser,) = item.user.call{value: item.amount}("");
        require(paidUser, "user");
        (bool paidFee,) = address(feeSink).call{value: fee}("");
        require(paidFee, "fee");
    }

    receive() external payable {}
}

contract Depositor {
    CampBridge public immutable bridge;

    constructor(CampBridge _bridge) {
        bridge = _bridge;
    }

    function deposit(uint256 amount) external payable {
        bridge.bridgeOut{value: amount}(amount);
    }

    receive() external payable {}
}

contract DepositorFixed {
    CampBridgeFixed public immutable bridge;

    constructor(CampBridgeFixed _bridge) {
        bridge = _bridge;
    }

    function deposit(uint256 amount) external payable {
        uint256 fee = amount / 10;
        bridge.bridgeOut{value: amount + fee}(amount);
    }

    receive() external payable {}
}

contract Exploit {
    uint256 public constant AMOUNT = 100 ether;
    CampBridge public bridge;
    FeeSink public feeSink;
    Depositor public alice;
    Depositor public bob;

    constructor() {
        feeSink = new FeeSink();
        bridge = new CampBridge(feeSink);
        alice = new Depositor(bridge);
        bob = new Depositor(bridge);
    }

    function run() external payable {
        require(msg.value == 2 * AMOUNT, "two deposits");
        alice.deposit{value: AMOUNT}(AMOUNT);
        bob.deposit{value: AMOUNT}(AMOUNT);
        require(address(bridge).balance == 2 * AMOUNT, "escrow 200");
        uint256 fee = AMOUNT / 10;
        require(fee == 10 ether, "fee is 10");
        bridge.send(0);
        require(address(alice).balance == AMOUNT, "alice bridged");
        require(address(feeSink).balance == fee, "fee taken");
        uint256 left = address(bridge).balance;
        require(left == AMOUNT - fee, "90 left");
        require(left < bobQueuedTotal(), "bob cannot bridge");
        require(bridge.queuedAmount(1) == AMOUNT, "bob still queued for 100");
        require(address(bob).balance == 0, "bob received 0");
    }

    function bobQueuedTotal() public pure returns (uint256) {
        return AMOUNT + AMOUNT / 10;
    }

    receive() external payable {}
}
