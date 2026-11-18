// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import "forge-std/Test.sol";
import {Exploit, Marketplace, Seller} from "./17097-remote-code-execution-through-arbitrary-erc20-implementation.sol";

contract HonestToken {
    mapping(address => uint256) public balanceOf;
    function mint(address to, uint256 amt) external { balanceOf[to] += amt; }
    function transfer(address to, uint256 amt) external returns (bool) {
        require(balanceOf[msg.sender] >= amt, "bal");
        balanceOf[msg.sender] -= amt;
        balanceOf[to] += amt;
        return true;
    }
    function transferFrom(address from, address to, uint256 amt) external returns (bool) {
        require(balanceOf[from] >= amt, "bal");
        balanceOf[from] -= amt;
        balanceOf[to] += amt;
        return true;
    }
}

contract Finding17097Test is Test {
    function test_exploit_malicious_currency_bricks_finalize() public {
        Exploit e = new Exploit();
        e.run();
        assertFalse(e.finalized(), "finalized");
        assertTrue(e.stuck(), "not stuck");
        assertEq(e.marketplace().offerStatus(e.listingId(), 0), 2, "status");
        assertEq(e.token().balanceOf(address(e.seller())), 0, "seller paid");
    }

    function test_control_honest_token_finalizes() public {
        Marketplace market = new Marketplace();
        Seller seller = new Seller();
        HonestToken token = new HonestToken();
        token.mint(address(this), 1000 ether);
        uint256 id = seller.create(market);
        market.makeOffer(id, address(token), 1000 ether);
        seller.accept(market, id, 0);
        assertTrue(seller.tryFinalize(market, id, 0), "finalize");
        assertEq(market.offerStatus(id, 0), 3, "final");
        assertEq(token.balanceOf(address(seller)), 1000 ether, "seller received");
    }
}
