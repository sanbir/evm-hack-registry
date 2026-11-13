// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import "forge-std/Test.sol";
import {
    Exploit,
    L1BridgeFixed,
    L2ERC1155Bridge,
    Token
} from "./60699-using-the-wrong-selector-causes-token-loss-during-erc1155-br.sol";

contract Finding60699Test is Test {
    function test_exploit_wrong_selector_keeps_the_batch() public {
        Exploit e = new Exploit();
        e.run();

        assertEq(e.stuck(), 1000 ether, "bridge did not keep N");
        assertEq(e.left(), 0, "user was refunded");
        assertEq(e.token().balanceOf(address(e.l1())), 1000 ether);
    }

    function test_control_batch_selector_refunds_n() public {
        Token token = new Token("Bridged 1155", "B1155", 18);
        L1BridgeFixed l1 = new L1BridgeFixed(token);
        L2ERC1155Bridge l2 = new L2ERC1155Bridge(address(l1));
        l1.setL2(address(l2));

        uint256[] memory ids = new uint256[](2);
        uint256[] memory amounts = new uint256[](2);
        ids[0] = 1;
        ids[1] = 2;
        amounts[0] = 400 ether;
        amounts[1] = 600 ether;
        token.mint(address(this), 1000 ether);
        token.approve(address(l1), 1000 ether);
        l1.finalizeWithdrawalBatch(address(this), ids, amounts, true);

        assertEq(token.balanceOf(address(this)), 1000 ether, "user did not get N back");
        assertEq(token.balanceOf(address(l1)), 0, "bridge kept the batch");
    }
}
