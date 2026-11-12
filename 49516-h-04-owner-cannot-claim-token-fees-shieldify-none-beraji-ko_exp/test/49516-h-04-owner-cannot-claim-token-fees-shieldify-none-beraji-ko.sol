// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

/*  Beraji KO — claimTokenFee zeros the fee then transfers that zero (Shieldify H-04, finding 49516).
    SYNTHETIC, cheatcode-free reduction for the EVM Playground.
    The lock holds a 1000 fee. claimTokenFee writes tokenFeeBalance = 0 and
    then safeTransfer(owner, tokenFeeBalance), so the owner is paid 0 and the
    1000 stays in the contract. The balance is now 0, so a later claim still
    pays nothing. The control caches the 1000 and pays the owner 1000.
    The blamed lines are preserved verbatim (@> VULN). run() does not warp. */

interface IERC20 {
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
}

library SafeTransfer {
    function safeTransfer(IERC20 token, address to, uint256 amount) internal {
        require(token.transfer(to, amount), "transfer");
    }
}

contract MockToken is IERC20 {
    string public name = "Stake";
    string public symbol = "KO";
    uint8 public constant decimals = 18;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 amount) external {
        totalSupply += amount;
        balanceOf[to] += amount;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        require(balanceOf[msg.sender] >= amount, "bal");
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        uint256 allowed = allowance[from][msg.sender];
        require(allowed >= amount && balanceOf[from] >= amount, "from");
        allowance[from][msg.sender] = allowed - amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

contract StakingKo {
    using SafeTransfer for IERC20;

    struct Pool {
        IERC20 stakingToken;
    }

    struct PoolLock {
        uint256 tokenFeeBalance;
        uint256 tokenFeeClaimed;
    }

    mapping(uint256 => Pool) public pools;
    mapping(uint256 => PoolLock[]) public mapPoolLocks;
    address public owner;

    constructor(address token, address owner_) {
        owner = owner_;
        pools[0].stakingToken = IERC20(token);
        mapPoolLocks[0].push(PoolLock(0, 0));
    }

    function accrue(uint256 amount) external {
        MockToken(address(pools[0].stakingToken)).transferFrom(msg.sender, address(this), amount);
        mapPoolLocks[0][0].tokenFeeBalance += amount;
    }

    function claimTokenFee(uint256 _poolId) external {
        require(msg.sender == owner, "only owner");
        Pool storage pool = pools[_poolId];
        PoolLock[] storage locks = mapPoolLocks[_poolId];
        for (uint256 lId = 0; lId < locks.length; lId++) {
            PoolLock storage lock = locks[lId];
            if (lock.tokenFeeBalance != 0) {
                lock.tokenFeeClaimed += lock.tokenFeeBalance;
                // @> VULN: the fee is cleared before it is used as the transfer amount
                lock.tokenFeeBalance = 0;
                pool.stakingToken.safeTransfer(msg.sender, lock.tokenFeeBalance);
            }
        }
    }

    function feeBalance() external view returns (uint256) {
        return mapPoolLocks[0][0].tokenFeeBalance;
    }
}

contract StakingKoFixed {
    using SafeTransfer for IERC20;

    struct Pool {
        IERC20 stakingToken;
    }

    struct PoolLock {
        uint256 tokenFeeBalance;
        uint256 tokenFeeClaimed;
    }

    mapping(uint256 => Pool) public pools;
    mapping(uint256 => PoolLock[]) public mapPoolLocks;
    address public owner;

    constructor(address token, address owner_) {
        owner = owner_;
        pools[0].stakingToken = IERC20(token);
        mapPoolLocks[0].push(PoolLock(0, 0));
    }

    function accrue(uint256 amount) external {
        MockToken(address(pools[0].stakingToken)).transferFrom(msg.sender, address(this), amount);
        mapPoolLocks[0][0].tokenFeeBalance += amount;
    }

    function claimTokenFee(uint256 _poolId) external {
        require(msg.sender == owner, "only owner");
        Pool storage pool = pools[_poolId];
        PoolLock[] storage locks = mapPoolLocks[_poolId];
        for (uint256 lId = 0; lId < locks.length; lId++) {
            PoolLock storage lock = locks[lId];
            if (lock.tokenFeeBalance != 0) {
                uint256 fee = lock.tokenFeeBalance;
                lock.tokenFeeClaimed += fee;
                lock.tokenFeeBalance = 0;
                pool.stakingToken.safeTransfer(msg.sender, fee);
            }
        }
    }
}

contract Exploit {
    uint256 public constant AMOUNT = 1000 ether;

    MockToken public token; // CREATE nonce 1
    StakingKo public staking; // CREATE nonce 2
    StakingKoFixed public control; // CREATE nonce 3

    uint256 public paidVuln;
    uint256 public stuck;
    uint256 public feeLeft;
    uint256 public paidControl;

    constructor() {
        token = new MockToken();
        staking = new StakingKo(address(token), address(this));
        control = new StakingKoFixed(address(token), address(this));
        token.mint(address(this), AMOUNT * 2);
    }

    function run() external {
        token.approve(address(staking), AMOUNT);
        staking.accrue(AMOUNT);

        uint256 ownerBefore = token.balanceOf(address(this));
        staking.claimTokenFee(0);
        paidVuln = token.balanceOf(address(this)) - ownerBefore;
        stuck = token.balanceOf(address(staking));
        feeLeft = staking.feeBalance();
        require(paidVuln == 0, "owner was paid");
        require(stuck == AMOUNT, "fee did not stay");
        require(feeLeft == 0, "fee balance was not wiped");

        token.approve(address(control), AMOUNT);
        control.accrue(AMOUNT);
        uint256 ownerMid = token.balanceOf(address(this));
        control.claimTokenFee(0);
        paidControl = token.balanceOf(address(this)) - ownerMid;
        require(paidControl == AMOUNT, "control did not pay the owner");
        require(token.balanceOf(address(control)) == 0, "control kept the fee");
    }
}
