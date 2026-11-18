// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

/*  Balmy — Lido delayed withdrawal hint (Cantina, 2024-11)
    LidoSTETHDelayedWithdrawalAdapter asks findCheckpointHints for
    lastIndex = requestsToClaim.length + 1. Lido's queue has last checkpoint
    562, and request 59498 was finalized at checkpoint 555. The short range
    returns hint 0, and claimWithdrawalsTo reverts, so the 1 ETH stays in the
    queue. Passing getLastCheckpointIndex() returns hint 555 and pays the ETH. */

contract Eth {
    string public symbol = "ETH";
    uint8 public constant decimals = 18;
    address public minter;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    constructor() {
        minter = msg.sender;
    }

    function mint(address to, uint256 amount) external {
        require(msg.sender == minter, "minter");
        balanceOf[to] += amount;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        allowance[from][msg.sender] -= amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

contract WithdrawalQueue {
    uint256 public constant REQUEST_ID = 59498;
    uint256 public constant CHECKPOINT = 555;
    uint256 public lastCheckpointIndex = 562;
    Eth public eth;
    bool public claimed;

    constructor(Eth _eth) {
        eth = _eth;
    }

    function getLastCheckpointIndex() external view returns (uint256) {
        return lastCheckpointIndex;
    }

    function findCheckpointHints(uint256[] calldata ids, uint256 first, uint256 last)
        external
        view
        returns (uint256[] memory hints)
    {
        if (first == 0 || last > lastCheckpointIndex) revert("InvalidRequestIdRange");
        hints = new uint256[](ids.length);
        for (uint256 i; i < ids.length; ++i) {
            if (ids[i] == REQUEST_ID && CHECKPOINT >= first && CHECKPOINT <= last) {
                hints[i] = CHECKPOINT;
            }
        }
    }

    function claimWithdrawalsTo(uint256[] calldata ids, uint256[] calldata hints, address recipient) external {
        for (uint256 i; i < ids.length; ++i) {
            if (ids[i] != REQUEST_ID || hints[i] != CHECKPOINT || claimed) revert("BadHint");
            claimed = true;
            require(eth.transfer(recipient, 1 ether), "pay");
        }
    }
}

contract LidoAdapter {
    WithdrawalQueue public queue;
    address public manager;
    uint256[] public pending;

    constructor(WithdrawalQueue _queue) {
        queue = _queue;
        manager = msg.sender;
        pending.push(59498);
    }

    function withdraw(uint256, address, address recipient) external returns (uint256 withdrawn, uint256 stillPending) {
        require(msg.sender == manager, "manager");
        uint256[] memory requestsToClaim = pending;
        // @> VULN: last index is requestsToClaim.length + 1, not getLastCheckpointIndex()
        uint256[] memory hints = queue.findCheckpointHints(requestsToClaim, 1, requestsToClaim.length + 1);
        // FIX: queue.findCheckpointHints(requestsToClaim, 1, queue.getLastCheckpointIndex())
        queue.claimWithdrawalsTo(requestsToClaim, hints, recipient);
        withdrawn = 1 ether;
        stillPending = 0;
    }
}

contract User {}

contract Exploit {
    Eth public eth; // nonce 1
    WithdrawalQueue public queue; // nonce 2
    LidoAdapter public adapter; // nonce 3
    User public user; // nonce 4

    constructor() {
        eth = new Eth();
        queue = new WithdrawalQueue(eth);
        adapter = new LidoAdapter(queue);
        user = new User();
        eth.mint(address(queue), 1 ether);
    }

    function run() external {
        (bool ok,) = address(adapter).call(
            abi.encodeWithSelector(adapter.withdraw.selector, uint256(1), address(eth), address(user))
        );
        require(!ok, "withdraw should revert");
        require(eth.balanceOf(address(queue)) == 1 ether, "eth left the queue");
        require(eth.balanceOf(address(user)) == 0, "user was paid");
        require(!queue.claimed(), "claimed");
    }
}
