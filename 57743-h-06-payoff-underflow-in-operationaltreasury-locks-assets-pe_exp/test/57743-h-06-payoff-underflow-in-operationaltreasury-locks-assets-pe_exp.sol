// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {
    Exploit,
    AssetToken,
    Pool,
    PositionClose,
    IPositionInteraction
} from "./57743-h-06-payoff-underflow-in-operationaltreasury-locks-assets-pe.sol";

/// Warden's cap: fees cannot exceed pnl, so the subtraction cannot underflow.
/// The trader is paid the fair net (here 0, because the fee consumes the whole pnl)
/// and the pool exercise commits, so the 1,000 collateral is no longer stuck.
contract OperationalTreasuryFixed {
    uint256 internal constant BPS = 10_000;

    AssetToken public token;
    address public pool;
    uint256 public protocolFees = 200;
    uint256 public price = 101e18;
    uint256 public strike = 100e18;
    uint256 public amount = 100e18;
    uint256 public collectedFees;
    uint256 public paidNet;

    constructor(address _token, address _pool) {
        token = AssetToken(_token);
        pool = _pool;
    }

    function payOff(uint256 positionID, address account) external returns (uint256 netAmount) {
        uint256 pnl = (amount * (price - strike)) / 1e18;
        uint256 feesUSD = (amount * protocolFees * price) / (BPS * 1e18);
        IPositionInteraction(pool).exerciseOrLiquidatePosition(PositionClose({positionID: positionID, pnl: pnl}));

        if (feesUSD > pnl) feesUSD = pnl;
        netAmount = pnl - feesUSD;
        collectedFees = feesUSD;
        paidNet = netAmount;
        if (netAmount > 0) token.transfer(account, netAmount);
    }
}

contract Finding57743Test is Test {
    function test_exploit_payoff_reverts_and_locks_1000_assets() public {
        Exploit e = new Exploit();
        e.run();

        assertTrue(e.payoffReverted(), "payOff reverted");
        assertEq(e.seenPnl(), 100e18, "pnl");
        assertEq(e.seenFees(), 202e18, "fees exceed pnl");
        assertEq(e.lockedAssets(), 1000e18, "1000 assets stuck");
        assertEq(e.token().balanceOf(address(e.pool())), 1000e18, "pool still holds the collateral");
        assertEq(e.pool().lockedOf(e.POSITION()), 1000e18, "position lock intact");
        assertFalse(e.pool().exercised(e.POSITION()), "exercise rolled back");
        assertEq(e.token().balanceOf(e.HOLDER()), 0, "holder received nothing");
        assertEq(e.treasury().collectedFees(address(e.token())), 0, "fee accounting rolled back");
    }

    function test_control_saturating_path_pays_fair_net_and_closes() public {
        AssetToken token = new AssetToken();
        Pool pool = new Pool(address(token));
        OperationalTreasuryFixed fixedTreasury = new OperationalTreasuryFixed(address(token), address(pool));
        address holder = address(0xBEEF);

        token.mint(address(pool), 1000e18);
        pool.noteLock(1, 1000e18);

        uint256 netAmount = fixedTreasury.payOff(1, holder);

        assertEq(netAmount, 0, "fair net is 0 once the fee is capped at pnl");
        assertEq(fixedTreasury.paidNet(), 0, "holder is paid the fair net");
        assertEq(token.balanceOf(holder), 0, "holder balance matches the fair net");
        assertEq(fixedTreasury.collectedFees(), 100e18, "capped fee equals the 100 pnl");
        assertEq(token.balanceOf(address(fixedTreasury)), 100e18, "treasury received the pnl");
        assertTrue(pool.exercised(1), "position closed");
        assertEq(pool.lockedOf(1), 0, "position lock released");
        assertEq(token.balanceOf(address(pool)), 900e18, "100 of the 1000 left the pool; 900 is free");
    }
}
