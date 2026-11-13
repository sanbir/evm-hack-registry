// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

/*  UFarmPool.withdraw (Hexens, June 2025).
    When withdrawalLockupPeriod > 0 the investor branch records the request
    and returns before withdrawQueue.push. The shares and the underlying
    stay in the pool. A later call that has passed the lockup still returns
    after flipping the pool to Deactivating.
*/

contract ValueToken {
    string public symbol = "USDT";
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
        uint256 allowed = allowance[from][msg.sender];
        if (allowed != type(uint256).max) allowance[from][msg.sender] = allowed - amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

contract UFarmPool {
    uint256 public constant LOCKUP = 7 days;
    uint8 public constant ACTIVE = 0;
    uint8 public constant DEACTIVATING = 1;

    ValueToken public immutable token;
    uint256 public withdrawalLockupPeriod;
    uint8 public status;
    uint256 public queuedShares;
    uint256 public queuedAssets;
    mapping(address => uint256) public sharesOf;
    mapping(bytes32 => uint256) public pendingWithdrawalsRequests;

    constructor(ValueToken _token) {
        token = _token;
        withdrawalLockupPeriod = LOCKUP;
        status = ACTIVE;
    }

    function deposit(uint256 amount) external {
        token.transferFrom(msg.sender, address(this), amount);
        sharesOf[msg.sender] += amount;
    }

    function withdraw(uint256 sharesToBurn) external {
        require(sharesOf[msg.sender] >= sharesToBurn, "shares");
        bytes32 withdrawalRequestHash = keccak256(abi.encode(msg.sender, sharesToBurn));
        if (withdrawalLockupPeriod > 0) {
            if (pendingWithdrawalsRequests[withdrawalRequestHash] == 0) {
                pendingWithdrawalsRequests[withdrawalRequestHash] = block.timestamp;
            } else {
                uint256 unlockTime = pendingWithdrawalsRequests[withdrawalRequestHash] + withdrawalLockupPeriod;
                require(block.timestamp >= unlockTime, "lockup");
                status = DEACTIVATING;
            }
            // @> VULN: both lockup steps return before the withdrawal is queued
            return;
        }
        _queue(sharesToBurn);
    }

    function _queue(uint256 sharesToBurn) internal {
        queuedShares += sharesToBurn;
        queuedAssets += sharesToBurn;
        sharesOf[msg.sender] -= sharesToBurn;
        token.transfer(msg.sender, sharesToBurn);
    }
}

contract UFarmPoolFixed {
    ValueToken public immutable token;
    uint256 public withdrawalLockupPeriod;
    uint256 public queuedShares;
    mapping(address => uint256) public sharesOf;
    mapping(bytes32 => uint256) public pendingWithdrawalsRequests;

    constructor(ValueToken _token) {
        token = _token;
        withdrawalLockupPeriod = 7 days;
    }

    function deposit(uint256 amount) external {
        token.transferFrom(msg.sender, address(this), amount);
        sharesOf[msg.sender] += amount;
    }

    function withdraw(uint256 sharesToBurn) external {
        require(sharesOf[msg.sender] >= sharesToBurn, "shares");
        bytes32 withdrawalRequestHash = keccak256(abi.encode(msg.sender, sharesToBurn));
        if (withdrawalLockupPeriod > 0 && pendingWithdrawalsRequests[withdrawalRequestHash] == 0) {
            pendingWithdrawalsRequests[withdrawalRequestHash] = block.timestamp;
        }
        queuedShares += sharesToBurn;
        sharesOf[msg.sender] -= sharesToBurn;
        token.transfer(msg.sender, sharesToBurn);
    }
}

contract Exploit {
    uint256 public constant AMOUNT = 100e18;
    ValueToken public token;
    UFarmPool public pool;

    constructor() {
        token = new ValueToken();
        pool = new UFarmPool(token);
        token.mint(address(this), AMOUNT);
    }

    function run() external {
        token.approve(address(pool), AMOUNT);
        pool.deposit(AMOUNT);
        uint256 shares = pool.sharesOf(address(this));
        require(shares == AMOUNT, "100 shares");
        require(token.balanceOf(address(pool)) == AMOUNT, "pool holds 100");
        uint256 beforeBal = token.balanceOf(address(this));
        pool.withdraw(AMOUNT);
        uint256 afterBal = token.balanceOf(address(this));
        require(afterBal == beforeBal, "paid 0");
        require(pool.queuedShares() == 0, "queue empty");
        require(pool.sharesOf(address(this)) == AMOUNT, "shares stuck");
        require(token.balanceOf(address(pool)) == AMOUNT, "100 stuck");
        require(pool.withdrawalLockupPeriod() > 0, "lockup on");
    }
}
