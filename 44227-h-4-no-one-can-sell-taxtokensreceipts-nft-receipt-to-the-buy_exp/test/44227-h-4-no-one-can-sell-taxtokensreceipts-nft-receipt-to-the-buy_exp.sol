// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import "forge-std/Test.sol";
import {Exploit, TaxTokensReceipt, BuyOrder, Cash, Registry} from
    "./44227-h-4-no-one-can-sell-taxtokensreceipts-nft-receipt-to-the-buy.sol";

contract Finding44227Test is Test {
    function test_exploit_sell_reverts_and_escrow_stays() public {
        Exploit e = new Exploit();
        e.run();

        assertTrue(e.saleReverted(), "reverted");
        assertEq(e.aliceCash(), 0, "alice");
        assertEq(e.orderCash(), 1000 ether, "escrow");
        assertEq(e.nftOwner(), address(e.alice()), "owner");
    }

    function test_control_authorized_loan_can_transfer_and_get_paid() public {
        Cash cash = new Cash();
        Registry registry = new Registry();
        TaxTokensReceipt receipt = new TaxTokensReceipt(registry);
        BuyOrder buyOrder = new BuyOrder(cash, address(receipt));
        address alice = address(uint160(0xA11CE));

        receipt.mint(alice, 7);
        cash.mint(address(buyOrder), 1000 ether);
        registry.markLoan(alice);

        vm.prank(alice);
        buyOrder.sellNFT(7);

        assertEq(cash.balanceOf(alice), 1000 ether, "paid");
        assertEq(receipt.ownerOf(7), address(buyOrder), "sold");
        assertEq(cash.balanceOf(address(buyOrder)), 0, "escrow empty");
    }
}
