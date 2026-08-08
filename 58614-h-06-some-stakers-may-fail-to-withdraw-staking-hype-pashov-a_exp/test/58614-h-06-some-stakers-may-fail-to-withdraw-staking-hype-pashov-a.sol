// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*//////////////////////////////////////////////////////////////////////////
    Kinetiq — [H-06] Some stakers may fail to withdraw staking HYPE
    (Pashov Audit Group, Kinetiq-security-review_2025-02-26, #58614)

    SYNTHETIC, CHEATCODE-FREE reduction for the EVM Playground.
    Root cause: queueWithdrawal always calls _withdrawFromValidator without
    first servicing the withdrawal from hypeBuffer. After a delegation switch
    (current validator has insufficient balance), queueWithdrawal reverts even
    though the buffer alone could pay the user — stakers fail to withdraw.
//////////////////////////////////////////////////////////////////////////*/

contract KHYPE {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    uint256 public totalSupply;

    function mint(address to, uint256 amt) external {
        balanceOf[to] += amt;
        totalSupply += amt;
    }

    function approve(address spender, uint256 amt) external returns (bool) {
        allowance[msg.sender][spender] = amt;
        return true;
    }

    function transferFrom(address from, address to, uint256 amt) external returns (bool) {
        require(balanceOf[from] >= amt, "bal");
        uint256 a = allowance[from][msg.sender];
        require(a >= amt, "allow");
        if (a != type(uint256).max) allowance[from][msg.sender] = a - amt;
        balanceOf[from] -= amt;
        balanceOf[to] += amt;
        return true;
    }
}

contract L1Write {
    mapping(address => uint256) public delegated; // validator => amount

    // uint256 amount — isolate H-06 (buffer) from H-05 (uint64 cast).
    function sendTokenDelegate(address validator, uint256 amount, bool isUndelegate) external {
        if (isUndelegate) {
            require(delegated[validator] >= amount, "insufficient validator stake");
            delegated[validator] -= amount;
        } else {
            delegated[validator] += amount;
        }
    }
}

/// @notice Reduced StakingManager: buffer on stake, but withdraw ignores buffer.
contract StakingManager {
    KHYPE public immutable kHYPE;
    L1Write public immutable l1Write;

    uint256 public hypeBuffer;
    uint256 public targetBuffer;
    address public currentDelegation;
    uint256 public totalStaked;
    uint256 public totalQueuedWithdrawals;
    mapping(address => uint256) public pending;

    uint256 public lastValidatorWithdrawAmount; // observability
    uint256 public validatorWithdrawCalls;

    constructor(KHYPE _k, L1Write _l1, address _validator, uint256 _targetBuffer) {
        kHYPE = _k;
        l1Write = _l1;
        currentDelegation = _validator;
        targetBuffer = _targetBuffer;
    }

    function stake() external payable {
        require(msg.value > 0, "zero");
        totalStaked += msg.value;
        kHYPE.mint(msg.sender, msg.value);
        _distributeStake(msg.value);
    }

    function _distributeStake(uint256 amount) internal {
        // Fill buffer first (matches production intent).
        if (hypeBuffer < targetBuffer) {
            uint256 need = targetBuffer - hypeBuffer;
            uint256 toBuffer = amount < need ? amount : need;
            hypeBuffer += toBuffer;
            amount -= toBuffer;
        }
        if (amount > 0) {
            address delegateTo = currentDelegation;
            require(delegateTo != address(0), "No delegation set");
            l1Write.sendTokenDelegate(delegateTo, amount, false);
            // ETH conceptually moved to L1; keep accounting only.
        }
    }

    function setDelegation(address newValidator) external {
        currentDelegation = newValidator;
    }

    function queueWithdrawal(uint256 amount) external {
        require(amount > 0, "Invalid amount");
        require(kHYPE.balanceOf(msg.sender) >= amount, "Insufficient kHYPE balance");

        kHYPE.transferFrom(msg.sender, address(this), amount);
        pending[msg.sender] += amount;
        totalQueuedWithdrawals += amount;

        address current = currentDelegation;
        require(current != address(0), "No delegation set");

        // Source: queueWithdrawal always undelegate full amount from current validator.
        _withdrawFromValidator(current, amount); // @> VULN: never services withdrawal from hypeBuffer first — forces validator exit even when buffer covers the amount
        // FIX: pull from hypeBuffer first; only undelegate the shortfall.
    }

    function _withdrawFromValidator(address validator, uint256 amount) internal {
        lastValidatorWithdrawAmount = amount;
        validatorWithdrawCalls += 1;
        l1Write.sendTokenDelegate(validator, amount, true);
    }

    /// @dev Correct path (control): use buffer before validator exit.
    function queueWithdrawalFixed(uint256 amount) external {
        require(amount > 0, "Invalid amount");
        require(kHYPE.balanceOf(msg.sender) >= amount, "Insufficient kHYPE balance");
        kHYPE.transferFrom(msg.sender, address(this), amount);
        pending[msg.sender] += amount;
        totalQueuedWithdrawals += amount;

        uint256 fromBuffer = amount < hypeBuffer ? amount : hypeBuffer;
        hypeBuffer -= fromBuffer;
        uint256 shortfall = amount - fromBuffer;
        if (shortfall > 0) {
            _withdrawFromValidator(currentDelegation, shortfall);
        }
    }

    receive() external payable {}
}

/// @dev User helper for distinct msg.sender.
contract User {
    StakingManager public mgr;
    KHYPE public kHYPE;

    constructor(StakingManager _m, KHYPE _k) {
        mgr = _m;
        kHYPE = _k;
    }

    function doStake() external payable {
        mgr.stake{value: msg.value}();
    }

    function approveAll() external {
        kHYPE.approve(address(mgr), type(uint256).max);
    }

    function tryQueue(uint256 amount) external returns (bool ok) {
        try mgr.queueWithdrawal(amount) {
            return true;
        } catch {
            return false;
        }
    }

    function tryQueueFixed(uint256 amount) external returns (bool ok) {
        try mgr.queueWithdrawalFixed(amount) {
            return true;
        } catch {
            return false;
        }
    }
}

/// CREATE order: kHYPE (1), l1 (2), manager (3), user (4).
contract Exploit {
    KHYPE public kHYPE;
    L1Write public l1;
    StakingManager public manager;
    User public user;

    address public constant VAL_A = address(0xA);
    address public constant VAL_B = address(0xB);

    bool public withdrawFailed;
    uint256 public bufferAtFail;

    constructor() {
        kHYPE = new KHYPE(); // 1
        l1 = new L1Write(); // 2
        // targetBuffer = 50 ether
        manager = new StakingManager(kHYPE, l1, VAL_A, 50 ether); // 3
        user = new User(manager, kHYPE); // 4
    }

    function run() external payable {
        require(msg.value >= 100 ether, "need 100 HYPE");

        // User A stakes 100 HYPE, targetBuffer=50 → 50 buffer, 50 delegated to VAL_A.
        user.doStake{value: 100 ether}();
        user.approveAll();
        require(manager.hypeBuffer() == 50 ether, "buffer filled");
        require(l1.delegated(VAL_A) == 50 ether, "50 on A");

        // Operator switches current delegation to VAL_B (0 stake on B) — common rebalance.
        manager.setDelegation(VAL_B);

        // User tries to withdraw 40 HYPE. Buffer has 50, but buggy path ignores buffer
        // and undelegates 40 from VAL_B (which has 0) → reverts. Staker fails to withdraw.
        bufferAtFail = manager.hypeBuffer();
        withdrawFailed = !user.tryQueue(40 ether);

        require(bufferAtFail == 50 ether, "buffer still full");
        require(withdrawFailed, "queue should fail without buffer use");
        require(manager.pending(address(user)) == 0, "pending rolled back");
        // Control: fixed path services 40 from buffer, no validator call needed.
        require(user.tryQueueFixed(40 ether), "fixed path should succeed");
        require(manager.hypeBuffer() == 10 ether, "buffer consumed");
        require(manager.pending(address(user)) == 40 ether, "queued via buffer");

        require(withdrawFailed && bufferAtFail >= 40 ether, "harm not demonstrated");
    }

    receive() external payable {}
}
