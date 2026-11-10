// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

/*  Rio — settleEpochFromEigenLayer marks the epoch settled and does not
    increment currentEpoch (Sherlock, finding #30896, H-1).

    SYNTHETIC, cheatcode-free, single block. Alice's 10-token withdrawal is
    queued and settled. Bob then queues another 10 into that same epoch.
    His later withdraw hits WITHDRAWALS_ALREADY_QUEUED_FOR_EPOCH and reverts.
    Bob's 10 stays in the queue. The fixed queue increments the epoch when
    the settlement is queued, so Bob's 10 is the next epoch and he is paid. */

contract MockToken {
    string public name = "Rio ETH";
    string public symbol = "ETH";
    uint8 public decimals = 18;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    uint256 public totalSupply;
    event Transfer(address indexed from, address indexed to, uint256 value);

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply += amount;
        emit Transfer(address(0), to, amount);
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        emit Transfer(msg.sender, to, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        if (msg.sender != from) allowance[from][msg.sender] -= amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        emit Transfer(from, to, amount);
        return true;
    }
}

contract RioLRTWithdrawalQueue {
    error EPOCH_ALREADY_SETTLED();
    error WITHDRAWALS_ALREADY_QUEUED_FOR_EPOCH();
    error WITHDRAWALS_NOT_QUEUED_FOR_EPOCH();
    error NO_SHARES_OWED_IN_EPOCH();
    error NO_SHARES_OWED();
    error EPOCH_NOT_SETTLED();
    error WITHDRAWAL_ALREADY_CLAIMED();

    struct EpochWithdrawals {
        bool settled;
        uint256 sharesOwed;
        uint256 assetsReceived;
        bytes32 aggregateRoot;
    }

    MockToken public immutable token;
    mapping(address => uint256) public currentEpoch;
    mapping(address => mapping(uint256 => EpochWithdrawals)) public epochs;
    mapping(address => mapping(uint256 => mapping(address => uint256))) public userShares;
    mapping(address => mapping(uint256 => mapping(address => bool))) public claimed;

    constructor(MockToken token_) {
        token = token_;
    }

    function queueWithdrawal(address withdrawer, uint256 sharesOwed) external {
        if (sharesOwed == 0) revert NO_SHARES_OWED();
        address asset = address(token);
        uint256 epoch = currentEpoch[asset];
        epochs[asset][epoch].sharesOwed += sharesOwed;
        userShares[asset][epoch][withdrawer] += sharesOwed;
        token.transferFrom(withdrawer, address(this), sharesOwed);
    }

    function queueCurrentEpochSettlement(bytes32 aggregateRoot) public virtual {
        if (aggregateRoot == bytes32(0)) revert WITHDRAWALS_NOT_QUEUED_FOR_EPOCH();
        address asset = address(token);
        uint256 epoch = currentEpoch[asset];
        EpochWithdrawals storage epochWithdrawals = epochs[asset][epoch];
        if (epochWithdrawals.aggregateRoot != bytes32(0)) revert WITHDRAWALS_ALREADY_QUEUED_FOR_EPOCH();
        if (epochWithdrawals.sharesOwed == 0) revert NO_SHARES_OWED_IN_EPOCH();
        if (epochWithdrawals.settled) revert EPOCH_ALREADY_SETTLED();
        epochWithdrawals.aggregateRoot = aggregateRoot;
    }

    function settleEpochFromEigenLayer(uint256 epoch) external {
        address asset = address(token);
        EpochWithdrawals storage epochWithdrawals = epochs[asset][epoch];
        if (epochWithdrawals.sharesOwed == 0) revert NO_SHARES_OWED_IN_EPOCH();
        if (epochWithdrawals.settled) revert EPOCH_ALREADY_SETTLED();
        if (epochWithdrawals.aggregateRoot == bytes32(0)) revert WITHDRAWALS_NOT_QUEUED_FOR_EPOCH();
        epochWithdrawals.settled = true;
        // @> VULN: assetsReceived is frozen here and currentEpoch is not incremented
        epochWithdrawals.assetsReceived = epochWithdrawals.sharesOwed;
    }

    function claim(uint256 epoch) external returns (uint256 amountOut) {
        address asset = address(token);
        EpochWithdrawals storage epochWithdrawals = epochs[asset][epoch];
        if (!epochWithdrawals.settled) revert EPOCH_NOT_SETTLED();
        uint256 owed = userShares[asset][epoch][msg.sender];
        if (owed == 0) revert NO_SHARES_OWED();
        if (claimed[asset][epoch][msg.sender]) revert WITHDRAWAL_ALREADY_CLAIMED();
        claimed[asset][epoch][msg.sender] = true;
        amountOut = owed * epochWithdrawals.assetsReceived / epochWithdrawals.sharesOwed;
        token.transfer(msg.sender, amountOut);
    }

    /// @notice The later withdraw. Reverts while this epoch is already queued.
    function withdrawRemaining() external {
        address asset = address(token);
        uint256 epoch = currentEpoch[asset];
        if (epochs[asset][epoch].aggregateRoot != bytes32(0)) revert WITHDRAWALS_ALREADY_QUEUED_FOR_EPOCH();
        settleCurrentEpoch();
    }

    function settleCurrentEpoch() public {
        address asset = address(token);
        uint256 epoch = currentEpoch[asset];
        EpochWithdrawals storage epochWithdrawals = epochs[asset][epoch];
        if (epochWithdrawals.sharesOwed == 0) revert NO_SHARES_OWED_IN_EPOCH();
        if (epochWithdrawals.settled) revert EPOCH_ALREADY_SETTLED();
        epochWithdrawals.settled = true;
        epochWithdrawals.assetsReceived = epochWithdrawals.sharesOwed;
        currentEpoch[asset] += 1;
    }
}

contract RioLRTWithdrawalQueueFixed is RioLRTWithdrawalQueue {
    constructor(MockToken token_) RioLRTWithdrawalQueue(token_) {}

    function queueCurrentEpochSettlement(bytes32 aggregateRoot) public override {
        super.queueCurrentEpochSettlement(aggregateRoot);
        currentEpoch[address(token)] += 1;
    }
}

contract User {
    function approveAndQueue(RioLRTWithdrawalQueue queue, MockToken token, uint256 amount) external {
        token.approve(address(queue), amount);
        queue.queueWithdrawal(address(this), amount);
    }

    function claim(RioLRTWithdrawalQueue queue, uint256 epoch) external {
        queue.claim(epoch);
    }

    function withdrawRemaining(RioLRTWithdrawalQueue queue) external {
        queue.withdrawRemaining();
    }
}

contract Exploit {
    MockToken public token;
    RioLRTWithdrawalQueue public queue;
    RioLRTWithdrawalQueueFixed public fixedQueue;
    User public alice;
    User public bob;

    uint256 public stuck;
    bool public lateWithdrawReverted;
    uint256 public epochAfterSettle;

    constructor() {
        token = new MockToken();
        queue = new RioLRTWithdrawalQueue(token);
        fixedQueue = new RioLRTWithdrawalQueueFixed(token);
        alice = new User();
        bob = new User();
        token.mint(address(alice), 10 ether);
        token.mint(address(bob), 10 ether);
    }

    function run() external {
        alice.approveAndQueue(queue, token, 10 ether);
        queue.queueCurrentEpochSettlement(bytes32(uint256(1)));
        queue.settleEpochFromEigenLayer(0);
        epochAfterSettle = queue.currentEpoch(address(token));
        alice.claim(queue, 0);
        bob.approveAndQueue(queue, token, 10 ether);
        (bool ok,) = address(bob).call(abi.encodeCall(User.withdrawRemaining, (queue)));
        lateWithdrawReverted = !ok;
        stuck = token.balanceOf(address(queue));
        require(epochAfterSettle == 0, "epoch was incremented");
        require(lateWithdrawReverted, "later withdraw did not revert");
        require(stuck == 10 ether, "Bob's 10 did not stay");
        require(token.balanceOf(address(bob)) == 0, "Bob was paid");
        require(token.balanceOf(address(alice)) == 10 ether, "Alice was not paid");
    }

    function control() external {
        alice.approveAndQueue(fixedQueue, token, 10 ether);
        fixedQueue.queueCurrentEpochSettlement(bytes32(uint256(1)));
        require(fixedQueue.currentEpoch(address(token)) == 1, "epoch not advanced");
        fixedQueue.settleEpochFromEigenLayer(0);
        alice.claim(fixedQueue, 0);
        bob.approveAndQueue(fixedQueue, token, 10 ether);
        bob.withdrawRemaining(fixedQueue);
        bob.claim(fixedQueue, 1);
        require(token.balanceOf(address(bob)) == 10 ether, "control did not pay Bob");
        require(token.balanceOf(address(fixedQueue)) == 0, "control left tokens stuck");
        require(token.balanceOf(address(alice)) == 10 ether, "control did not pay Alice");
    }
}
