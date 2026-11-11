// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {
    Exploit,
    Sale,
    WERC721Fixed,
    IRoyalty
} from "./46496-inaccurate-royalty-calculation-in-werc721royaltyinfo-functio.sol";

contract Finding46496Test is Test {
    address internal constant RECEIVER = 0x2222222222222222222222222222222222222222;
    address internal constant SELLER = 0x3333333333333333333333333333333333333333;

    function test_exploit_sale_pays_wrong_royalty() public {
        Exploit e = new Exploit();
        vm.deal(address(this), 2 ether);
        e.run{value: 1 ether}();

        assertEq(e.paidRoyalty(), 0.001 ether, "paid 0.001 ETH");
        assertEq(e.fairRoyalty(), 0.01 ether, "fair is 0.01 ETH");
        assertEq(RECEIVER.balance, 0.001 ether, "receiver was paid the wrong royalty");
        assertEq(SELLER.balance, 0.999 ether, "seller kept the 0.009 ETH gap");
    }

    function test_control_fixed_royalty_pays_one_percent() public {
        WERC721Fixed nft = new WERC721Fixed(RECEIVER);
        Sale sale = new Sale();
        vm.deal(address(this), 2 ether);
        uint256 paid = sale.buy{value: 1 ether}(IRoyalty(address(nft)), 1, payable(SELLER));

        assertEq(paid, 0.01 ether, "control pays the fair royalty");
        assertEq(RECEIVER.balance, 0.01 ether, "receiver got 1%");
        assertEq(SELLER.balance, 0.99 ether, "seller got the rest");
    }
}
