// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "./42876-h-01-standardpolicyerc1155sol-returns-amount-1-instead-of-am.sol";

/*//////////////////////////////////////////////////////////////
    Blur — StandardPolicyERC1155 amount hardcoded to 1 (#42876)
//////////////////////////////////////////////////////////////*/
contract BlurPolicyAmountTest is Test {
    function test_exploit() public {
        Exploit e = new Exploit();
        e.run();

        assertEq(e.nft().balanceOf(address(e), e.TOKEN_ID()), 1, "buyer got only 1");
        assertEq(e.nft().balanceOf(e.seller(), e.TOKEN_ID()), 9, "seller keeps 9");
        assertEq(e.weth().balanceOf(e.seller()), e.PRICE(), "seller full price");
        assertEq(e.weth().balanceOf(address(e)), 0, "buyer spent full price");
    }

    function test_policyReturnsOne() public {
        StandardPolicyERC1155 policy = new StandardPolicyERC1155();
        Order memory sell = Order({
            side: Side.Sell,
            trader: address(0xA),
            paymentToken: address(1),
            collection: address(2),
            tokenId: 7,
            matchingPolicy: address(policy),
            price: 100 ether,
            amount: 10
        });
        Order memory buy = Order({
            side: Side.Buy,
            trader: address(0xB),
            paymentToken: address(1),
            collection: address(2),
            tokenId: 7,
            matchingPolicy: address(policy),
            price: 100 ether,
            amount: 10
        });
        (bool ok, uint256 price, uint256 tokenId, uint256 amount, AssetType t) =
            policy.canMatchMakerAsk(sell, buy);
        assertTrue(ok);
        assertEq(price, 100 ether);
        assertEq(tokenId, 7);
        assertEq(amount, 1, "policy hardcodes 1");
        assertTrue(t == AssetType.ERC1155);
    }
}
