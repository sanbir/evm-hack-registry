// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*  Aegis — BGT rewards revert inside _preAction, so withdrawals freeze
    (Pashov H-01, finding 41320). SYNTHETIC, cheatcode-free.
    BGT.transfer allows only whitelisted senders. The rewards vault is
    whitelisted and can pay the Aegis vault, but the vault is not whitelisted,
    so _transferRewardsToFarmingContract reverts. withdraw() calls _preAction
    first, so a depositor cannot exit and the assets stay in the vault.
    @> VULN marks that transfer. */

contract ERC20 {
    string public name;
    string public symbol;
    uint8 public decimals = 18;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;

    constructor(string memory n, string memory s) {
        name = n;
        symbol = s;
    }

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply += amount;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        require(balanceOf[msg.sender] >= amount, "bal");
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

contract BGT {
    string public name = "Bera Governance Token";
    string public symbol = "BGT";
    uint8 public decimals = 18;
    mapping(address => uint256) public balanceOf;
    mapping(address => bool) public isWhitelistedSender;

    function setWhitelisted(address account, bool value) external {
        isWhitelistedSender[account] = value;
    }

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        require(isWhitelistedSender[msg.sender], "Not approved sender");
        require(balanceOf[msg.sender] >= amount, "bal");
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

contract RewardsVault {
    BGT public bgt;

    constructor(BGT bgt_) {
        bgt = bgt_;
    }

    function unstakeAndClaim(address to) external returns (uint256 amount) {
        amount = bgt.balanceOf(address(this));
        require(amount > 0, "no rewards");
        bgt.transfer(to, amount);
    }
}

contract AegisVault {
    ERC20 public asset;
    BGT public bgt;
    RewardsVault public rewardsVault;
    address public farming;
    mapping(address => uint256) public shares;
    uint256 public totalAssets;

    constructor(ERC20 asset_, BGT bgt_, RewardsVault rewardsVault_, address farming_) {
        asset = asset_;
        bgt = bgt_;
        rewardsVault = rewardsVault_;
        farming = farming_;
    }

    function seed(address user, uint256 amount) external {
        shares[user] = amount;
        totalAssets = amount;
    }

    function _transferRewardsToFarmingContract() internal {
        uint256 rewardBalance = bgt.balanceOf(address(this));
        if (rewardBalance > 0) {
            bgt.transfer(farming, rewardBalance); // @> VULN: vault forwards BGT without being an approved sender, so withdraw reverts
        }
    }

    function _preAction() internal {
        rewardsVault.unstakeAndClaim(address(this));
        _transferRewardsToFarmingContract();
    }

    function withdraw(uint256 amount) external {
        require(shares[msg.sender] >= amount, "shares");
        _preAction();
        shares[msg.sender] -= amount;
        totalAssets -= amount;
        asset.transfer(msg.sender, amount);
    }
}

contract AegisVaultFixed {
    ERC20 public asset;
    BGT public bgt;
    RewardsVault public rewardsVault;
    address public farming;
    mapping(address => uint256) public shares;
    uint256 public totalAssets;

    constructor(ERC20 asset_, BGT bgt_, RewardsVault rewardsVault_, address farming_) {
        asset = asset_;
        bgt = bgt_;
        rewardsVault = rewardsVault_;
        farming = farming_;
    }

    function seed(address user, uint256 amount) external {
        shares[user] = amount;
        totalAssets = amount;
    }

    function withdraw(uint256 amount) external {
        require(shares[msg.sender] >= amount, "shares");
        rewardsVault.unstakeAndClaim(address(this));
        uint256 rewardBalance = bgt.balanceOf(address(this));
        if (rewardBalance > 0 && bgt.isWhitelistedSender(address(this))) {
            bgt.transfer(farming, rewardBalance);
        }
        shares[msg.sender] -= amount;
        totalAssets -= amount;
        asset.transfer(msg.sender, amount);
    }
}

contract Exploit {
    ERC20 public asset; // nonce 1
    BGT public bgt; // nonce 2
    RewardsVault public rewardsVault; // nonce 3
    AegisVault public vault; // nonce 4
    address public farming; // plain address, not a create

    constructor() {
        asset = new ERC20("Vault Asset", "ASSET");
        bgt = new BGT();
        rewardsVault = new RewardsVault(bgt);
        farming = address(0xF00D);
        vault = new AegisVault(asset, bgt, rewardsVault, farming);
        bgt.setWhitelisted(address(rewardsVault), true);
        bgt.mint(address(rewardsVault), 50 ether);
        asset.mint(address(vault), 1000 ether);
        vault.seed(address(this), 1000 ether);
    }

    function run() external {
        require(!bgt.isWhitelistedSender(address(vault)), "vault cannot send BGT");
        require(bgt.isWhitelistedSender(address(rewardsVault)), "rewards vault can send BGT");
        require(vault.shares(address(this)) == 1000 ether, "depositor has shares");
        bool exited = true;
        try vault.withdraw(1000 ether) {
            exited = true;
        } catch {
            exited = false;
        }
        require(!exited, "withdraw reverted inside preAction");
        require(vault.shares(address(this)) == 1000 ether, "shares were not burned");
        require(asset.balanceOf(address(this)) == 0, "depositor received nothing");
        require(asset.balanceOf(address(vault)) == 1000 ether, "assets remain stuck in the vault");
        require(bgt.balanceOf(farming) == 0, "farming contract received no BGT");
    }
}
