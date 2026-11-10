// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {
    Asset,
    Exploit,
    LiquidationDistributor,
    Pool,
    Terms
} from "./35213-h-11-incorrect-protocol-fee-implementation-results-in-outsta.sol";

contract Finding35213Test is Test {
    address constant ATTACKER = 0x1111111111111111111111111111111111111111;
    address constant EXPLOIT = 0x15452EC016c4dc8c549E7fe6Ff4b26324Ea8b7A4;
    address constant ASSET = 0x8ea53755A6CB335DD77e8DfBE91078CF210015C7;
    address constant POOL = 0x671D353A77015fA0B747f24eb2a50b0E3340BD1d;
    address constant DISTRIBUTOR = 0xce01759B82FD6cbf9DA468ae79fdcACc4605a5c5;

    function _deploy() internal returns (Exploit e) {
        vm.setNonce(ATTACKER, 1);
        vm.prank(ATTACKER);
        e = new Exploit();
    }

    function test_liquidation_writes_off_pool_yield() public {
        Exploit e = _deploy();
        assertEq(address(e), EXPLOIT, "exploit");
        assertEq(address(e.asset()), ASSET, "asset");
        assertEq(address(e.pool()), POOL, "pool");
        assertEq(address(e.distributor()), DISTRIBUTOR, "distributor");

        e.run();

        assertEq(e.pool().sumApr(), Terms.LEFT_SUM, "sumApr");
        assertEq(e.pool().bookedAnnual(), 60 ether, "booked");
        assertEq(e.asset().balanceOf(POOL), 60 ether, "pool");
        assertEq(e.asset().balanceOf(Terms.SINK), Terms.SHORT, "sink");
        assertEq(e.pool().writtenOff(), Terms.SHORT, "short");
        assertEq(Terms.FAIR_LEFT_SUM - e.pool().sumApr(), 200_000 ether, "sum gap");
    }

    function test_control_fee_leaves_balances_matching() public {
        Asset asset = new Asset();
        Pool pool = new Pool(asset);
        asset.setMinter(address(pool));

        pool.validateOffer(Terms.PRINCIPAL, Terms.APR, Terms.FEE);
        pool.validateOffer(Terms.PRINCIPAL, Terms.APR, Terms.FEE);

        pool.loanLiquidation(2, Terms.PRINCIPAL, Terms.APR, 0, Terms.FEE, Terms.PRINCIPAL, block.timestamp);

        assertEq(pool.lastProtocolFee(), Terms.FEE, "fee");
        assertEq(pool.sumApr(), Terms.FAIR_LEFT_SUM, "sumApr");
        assertEq(pool.bookedAnnual(), Terms.NET_YIELD, "booked");
        assertEq(asset.balanceOf(address(pool)), Terms.NET_YIELD, "pool");
        assertEq(asset.balanceOf(Terms.SINK), 0, "sink");
        assertEq(pool.writtenOff(), 0, "short");
        assertEq(asset.balanceOf(Terms.CLOSED), Terms.NET_YIELD, "closed");
        assertEq(pool.principalOutstanding(), Terms.PRINCIPAL, "left");
    }
}
