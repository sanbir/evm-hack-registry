// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*  Elytra — elyAsset price multiplies the fee by 1e18 and underflows
    (Pashov, Elytra, July 2025).
    SYNTHETIC, cheatcode-free, one block. Solidity 0.8 reverts.
    totalValue is 1,050 ether, the fee is 5 ether, supply is 1,000 ether.
    fee * 1e18 is 5e36, and 1,050e18 - 5e36 underflows. The redeem reverts
    and 1,050 ASSET stays in the vault. The holder receives 0.
    Control subtracts the fee once and pays 1,045 ASSET. */

contract Asset {
    string public constant name = "ASSET";
    string public constant symbol = "ASSET";
    uint8 public constant decimals = 18;
    mapping(address => uint256) public balanceOf;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        require(balanceOf[msg.sender] >= amount, "bal");
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

contract ElyVault {
    Asset public asset;
    uint256 public totalValue = 1050 ether;
    uint256 public fee = 5 ether;
    uint256 public supply = 1000 ether;
    mapping(address => uint256) public shares;

    constructor(Asset asset_) {
        asset = asset_;
    }

    function mintShares(address to, uint256 amount) external {
        shares[to] = amount;
    }

    function price() public view returns (uint256) {
        // @> VULN: protocolFeeInHYPE is already 18 decimals; multiplying by 1e18 underflows the subtraction
        return (totalValue - (fee * 1 ether)) * 1 ether / supply;
    }

    function redeem(address user) external returns (uint256 payout) {
        uint256 px = price();
        payout = shares[user] * px / 1 ether;
        shares[user] = 0;
        asset.transfer(user, payout);
    }
}

contract ElyVaultFixed {
    Asset public asset;
    uint256 public totalValue = 1050 ether;
    uint256 public fee = 5 ether;
    uint256 public supply = 1000 ether;
    mapping(address => uint256) public shares;

    constructor(Asset asset_) {
        asset = asset_;
    }

    function mintShares(address to, uint256 amount) external {
        shares[to] = amount;
    }

    function price() public view returns (uint256) {
        // FIX: both values are already 18 decimals, so do not scale the fee again
        return (totalValue - fee) * 1 ether / supply;
    }

    function redeem(address user) external returns (uint256 payout) {
        uint256 px = price();
        payout = shares[user] * px / 1 ether;
        shares[user] = 0;
        asset.transfer(user, payout);
    }
}

contract Exploit {
    Asset public asset;
    ElyVault public vault;
    bool public reverted;
    uint256 public stuck;
    uint256 public received;

    constructor() {
        asset = new Asset();
        vault = new ElyVault(asset);
    }

    function run() external {
        asset.mint(address(vault), 1050 ether);
        vault.mintShares(address(this), 1000 ether);
        try vault.redeem(address(this)) returns (uint256) {
            reverted = false;
        } catch {
            reverted = true;
        }
        stuck = asset.balanceOf(address(vault));
        received = asset.balanceOf(address(this));
        require(reverted, "reverted");
        require(stuck == 1050 ether, "stuck");
        require(received == 0, "paid nothing");
        require(vault.shares(address(this)) == 1000 ether, "shares remain");
    }
}
