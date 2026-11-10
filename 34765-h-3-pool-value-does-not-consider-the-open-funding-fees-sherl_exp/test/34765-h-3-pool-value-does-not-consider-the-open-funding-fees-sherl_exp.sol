// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {
    Exploit,
    Asset,
    LpPool
} from "./34765-h-3-pool-value-does-not-consider-the-open-funding-fees-sherl.sol";

contract LpPoolFixed is LpPool {
    constructor(address _asset, address lp, uint256 baseAmount, uint256 funding)
        LpPool(_asset, lp, baseAmount, funding)
    {}

    function getPoolIntValue() public view override returns (int256 value) {
        if (amount > 0 || unsettledAmount > 0 || openFundingFee > 0) {
            value = tokenToUsdInt(amount + unsettledAmount + marketUnPnl + openFundingFee, 18, oraclePrice());
        }
    }
}

contract Finding34765Test is Test {
    function test_exploit_withdrawal_is_high_because_price_ignored_funding() public {
        Exploit e = new Exploit();
        e.run();
        assertEq(e.quotedPrice(), 1e18, "quoted share price 1e18");
        assertEq(e.fairPrice(), 2e18, "fair share price 2e18");
        assertEq(e.withdrawn(), 1500e18, "withdrew 1500");
        assertEq(e.fairWithdraw(), 1000e18, "fair withdrawal is 1000");
        assertEq(e.asset().balanceOf(address(e)) - 1000e18, 500e18, "500 taken from LPs");
        emit log_named_uint("quoted price", e.quotedPrice());
        emit log_named_uint("fair price", e.fairPrice());
        emit log_named_uint("withdrawn", e.withdrawn());
        emit log_named_uint("fair withdraw", e.fairWithdraw());
    }

    function test_control_value_includes_open_funding() public {
        Asset asset = new Asset();
        address lp = address(new ControlLp());
        LpPoolFixed pool = new LpPoolFixed(address(asset), lp, 1000e18, 1000e18);
        asset.mint(address(pool), 1000e18);
        asset.mint(address(this), 1000e18);

        uint256 price = pool.sharePrice();
        assertEq(price, 2e18, "control share price includes funding");

        asset.approve(address(pool), 1000e18);
        uint256 shares = pool.deposit(1000e18);
        assertEq(shares, 500e18, "control mints half as many shares");

        pool.realizeFunding();
        uint256 out = pool.withdraw(shares);
        assertEq(out, 1000e18, "control withdrawal returns the deposit");
        assertEq(asset.balanceOf(address(this)), 1000e18, "no profit once funding is in the price");
        emit log_named_uint("control price", price);
        emit log_named_uint("control withdraw", out);
    }
}

contract ControlLp {}
