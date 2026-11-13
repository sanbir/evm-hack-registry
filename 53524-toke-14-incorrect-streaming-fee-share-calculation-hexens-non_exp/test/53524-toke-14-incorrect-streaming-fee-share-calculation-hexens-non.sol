// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

/* Tokemak TOKE-14 (AuditVault 53524). _mintStreamingFee prices the fee
   off totalAssets. With 1000 assets, 1000 shares and 100 profit, a 10%
   streaming fee mints 111111111111111111111 shares. Redeeming them pays
   the sink 99999999999999999999 assets. The profit-based fix pays 10. */

contract Asset {
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

contract FeeVault {
    uint256 public constant FEE_DIVISOR = 10_000;
    Asset public asset;
    address public sink;
    bool public useProfit;
    uint256 public totalAssets;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;

    constructor(Asset asset_, address sink_, bool useProfit_) {
        asset = asset_;
        sink = sink_;
        useProfit = useProfit_;
    }

    function _calculateSharesToMintFeeCollection(uint256 feeBps, uint256 assets, uint256 supply)
        internal
        pure
        returns (uint256)
    {
        // @> VULN: fee assets are totalAssets times the fee bps, not the profit
        uint256 feeAssets = assets * feeBps / FEE_DIVISOR;
        return feeAssets * supply / (assets - feeAssets);
    }

    function _mint(address to, uint256 shares) internal {
        totalSupply += shares;
        balanceOf[to] += shares;
    }

    function load(uint256 assets, uint256 supply) external {
        totalAssets = assets;
        totalSupply = supply;
        balanceOf[address(0xA11CE)] = supply;
        asset.mint(address(this), assets);
    }

    function _mintStreamingFee(uint256 streamingFeeBps, uint256 assets, uint256 currentTotalSupply, uint256 profit)
        internal
        returns (uint256)
    {
        uint256 streamingFeeShares;
        if (useProfit) {
            uint256 fees = profit * streamingFeeBps;
            uint256 den = (assets * FEE_DIVISOR) - fees;
            streamingFeeShares = (fees * currentTotalSupply + den - 1) / den;
        } else {
            streamingFeeShares = _calculateSharesToMintFeeCollection(streamingFeeBps, assets, currentTotalSupply);
        }
        _mint(sink, streamingFeeShares);
        return streamingFeeShares;
    }

    function chargeAndRedeem(uint256 feeBps, uint256 profit) external returns (uint256 shares, uint256 paid) {
        shares = _mintStreamingFee(feeBps, totalAssets, totalSupply - 0, profit);
        uint256 supplyNow = totalSupply;
        paid = shares * totalAssets / supplyNow;
        totalSupply = supplyNow - shares;
        balanceOf[sink] -= shares;
        totalAssets -= paid;
        require(asset.transfer(sink, paid), "pay");
    }
}

contract Exploit {
    uint256 public constant ASSETS = 1_000 ether;
    uint256 public constant SUPPLY = 1_000 ether;
    uint256 public constant PROFIT = 100 ether;
    uint256 public constant BPS = 1_000;
    address public constant SINK = 0x000000000000000000000000000000000000D00d;

    Asset public asset;
    FeeVault public vault;
    FeeVault public fixedVault;
    uint256 public paid;
    uint256 public sharesMinted;
    uint256 public controlPaid;

    constructor() {
        asset = new Asset();
        vault = new FeeVault(asset, SINK, false);
        fixedVault = new FeeVault(asset, SINK, true);
    }

    function run() external {
        vault.load(ASSETS, SUPPLY);
        (sharesMinted, paid) = vault.chargeAndRedeem(BPS, PROFIT);
        require(sharesMinted == 111111111111111111111, "shares");
        require(paid == 99999999999999999999, "paid");
        require(asset.balanceOf(SINK) == paid, "sink");
    }

    function runControl() external {
        fixedVault.load(ASSETS, SUPPLY);
        (, controlPaid) = fixedVault.chargeAndRedeem(BPS, PROFIT);
        require(controlPaid == 10 ether, "fair");
        require(asset.balanceOf(SINK) == 10 ether, "sink");
    }
}
