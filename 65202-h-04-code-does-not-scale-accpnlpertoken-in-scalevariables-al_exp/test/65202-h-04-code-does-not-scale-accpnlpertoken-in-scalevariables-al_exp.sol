// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import "forge-std/Test.sol";
import {Exploit, Asset, Trader} from "./65202-h-04-code-does-not-scale-accpnlpertoken-in-scalevariables-al.sol";

contract FixedVault {
    int256 public accPnlPerToken = 0.1 ether;
    uint256 public totalShares = 100 ether;
    Asset public asset;
    address public trader;

    constructor(Asset _asset, address _trader) {
        asset = _asset;
        trader = _trader;
    }

    function deposit(uint256 assetsIn) external returns (uint256 shares) {
        uint256 pnl = uint256(accPnlPerToken * int256(totalShares) / 1 ether);
        uint256 equity = asset.balanceOf(address(this)) - pnl;
        shares = assetsIn * totalShares / equity;
        accPnlPerToken = accPnlPerToken * int256(totalShares) / int256(totalShares + shares);
        totalShares += shares;
        asset.pull(msg.sender, assetsIn);
    }

    function settle() external returns (uint256 paid) {
        paid = uint256(accPnlPerToken * int256(totalShares) / int256(1 ether));
        asset.transfer(trader, paid);
    }
}

contract Finding65202Test is Test {
    function test_exploit_settlement_off_by_10() public {
        Exploit e = new Exploit();
        e.run();
        assertEq(e.asset().balanceOf(address(e.trader())), e.PAID(), "paid 20");
        assertEq(e.PAID() - e.FAIR(), e.OFF_BY(), "off by 10");
    }

    function test_control_scales_positive_pnl() public {
        Asset asset = new Asset();
        Trader trader = new Trader();
        FixedVault vault = new FixedVault(asset, address(trader));
        asset.mint(address(vault), 100 ether);
        asset.mint(address(this), 90 ether);
        uint256 shares = vault.deposit(90 ether);
        uint256 paid = vault.settle();
        assertEq(shares, 100 ether, "100 shares");
        assertEq(paid, 10 ether, "fair settlement");
        assertEq(asset.balanceOf(address(trader)), 10 ether, "trader paid 10");
    }
}
