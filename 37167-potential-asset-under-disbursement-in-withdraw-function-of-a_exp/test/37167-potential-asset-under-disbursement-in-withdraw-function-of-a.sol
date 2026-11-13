// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*  Aarna AFiBase.withdraw — pays the token balance when it is below the
    entitlement, and still burns the shares (Zokyo, January 2024).

    The user is entitled to 1000 oToken. The contract holds 400. The else
    branch transfers 400. The shares are burned. Paid 400, fair 1000, short 600.

    The control reverts unless the balance covers the entitlement. Funding
    the vault to 1000 then pays 1000. run() does not warp. */

contract OToken {
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

contract AFiBase {
    OToken public oToken;
    uint256 public totalShares;
    uint256 public accountedAssets;
    mapping(address => uint256) public sharesOf;
    uint256 public lastPaid;
    uint256 public lastFair;

    constructor(OToken oToken_) {
        oToken = oToken_;
    }

    function deposit(address user, uint256 assets, uint256 shares) external {
        accountedAssets += assets;
        totalShares += shares;
        sharesOf[user] += shares;
    }

    function withdraw(uint256 shares) external virtual returns (uint256 paid) {
        uint256 redFromContract = accountedAssets * shares / totalShares;
        lastFair = redFromContract;
        if (oToken.balanceOf(address(this)) >= redFromContract) {
            oToken.transfer(msg.sender, redFromContract);
            paid = redFromContract;
        } else {
            // @> VULN: balance is below the entitlement, and the shortfall is not reverted or recorded
            paid = oToken.balanceOf(address(this));
            oToken.transfer(msg.sender, paid);
        }
        lastPaid = paid;
        sharesOf[msg.sender] -= shares;
        totalShares -= shares;
        accountedAssets -= redFromContract;
    }
}

contract AFiBaseFixed is AFiBase {
    constructor(OToken oToken_) AFiBase(oToken_) {}

    function withdraw(uint256 shares) external override returns (uint256 paid) {
        uint256 redFromContract = accountedAssets * shares / totalShares;
        require(oToken.balanceOf(address(this)) >= redFromContract, "short");
        oToken.transfer(msg.sender, redFromContract);
        paid = redFromContract;
        lastPaid = paid;
        lastFair = redFromContract;
        sharesOf[msg.sender] -= shares;
        totalShares -= shares;
        accountedAssets -= redFromContract;
    }
}

contract Exploit {
    uint256 public constant FAIR = 1000 ether;
    uint256 public constant PAID = 400 ether;
    uint256 public constant SHORT = 600 ether;

    OToken public token;
    AFiBase public vault;
    uint256 public paid;
    uint256 public fair;

    constructor() {
        token = new OToken();
        vault = new AFiBase(token);
        token.mint(address(vault), PAID);
        vault.deposit(address(this), FAIR, FAIR);
    }

    function run() external {
        paid = vault.withdraw(FAIR);
        fair = vault.lastFair();
        require(paid == PAID, "paid");
        require(fair == FAIR, "fair");
        require(fair - paid == SHORT, "short");
        require(vault.sharesOf(address(this)) == 0, "burned");
        require(token.balanceOf(address(this)) == PAID, "balance");
    }
}
