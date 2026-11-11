// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import "forge-std/Test.sol";
import {
    Exploit,
    ExchangeFixed,
    Nft,
    OrderPool
} from "./41367-h-03-orderamount-not-accounted-when-filling-pashov-audit-gro.sol";

contract Finding41367Test is Test {
    function test_exploit_fill_exceeds_order_amount() public {
        Exploit e = new Exploit();
        e.run{value: 1 ether}();

        assertEq(e.pool().orderAmount(), 2, "listed amount");
        assertEq(e.nft().balanceOf(address(e)), 5, "filler took 5");
        assertGt(e.nft().balanceOf(address(e)), e.pool().orderAmount(), "taken > order");
        assertEq(e.pool().filled(), 5, "pool recorded 5");
        assertEq(address(e.pool()).balance, 1 ether, "paid one unit price");
        emit log_named_uint("order_amount", e.pool().orderAmount());
        emit log_named_uint("taken", e.nft().balanceOf(address(e)));
        emit log_named_uint("paid_wei", address(e.pool()).balance);
    }

    function test_control_caps_fill_at_order_amount() public {
        Nft nft = new Nft();
        OrderPool pool = new OrderPool(nft);
        ExchangeFixed fixedRouter = new ExchangeFixed();
        nft.mint(address(pool), 10);

        ExchangeFixed.FulfillOrder memory order = ExchangeFixed.FulfillOrder({
            orderPool: pool,
            nftId: 1,
            amount: 5,
            price: 1 ether
        });
        fixedRouter.fillAskOrder{value: 2 ether}(order);

        assertEq(nft.balanceOf(address(this)), 2, "capped at order.amount");
        assertEq(pool.filled(), 2, "pool filled the cap");
        assertEq(nft.balanceOf(address(pool)), 8, "three extra NFTs stayed");
        assertEq(address(pool).balance, 2 ether, "paid price times the cap");
    }
}
