// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.27;

import "forge-std/Test.sol";
import {Exploit, GameNFT, SoulboundDoSMarker} from "./53286-h-03-soulbound-tokens-cannot-be-minted-or-burnt-due-to-an-in.sol";

// Gigaverse H-03 (finding 53286): GameNFT._update overrides OZ-v5 ERC721._update
// and reverts `require(!isSoulbound, ...)` on EVERY update. Since _mint and _burn
// both route through _update, a soulbound token can never be minted and, once
// soulbound, never burnt — a permanent DoS. Marker at the SINK records magnitude.
contract Finding53286Test is Test {
    address internal constant SINK = 0x000000000000000000000000000000000000D00d;

    function test_exploit_soulboundMintAndBurnBricked() public {
        Exploit e = new Exploit();
        e.run();

        GameNFT nft = e.nft();
        SoulboundDoSMarker marker = e.marker();

        // control: a normal (non-soulbound) token mints fine
        assertTrue(e.normalMintOk(), "normal mint should succeed");
        assertEq(nft.ownerOf(1), address(0xBEEF), "token 1 owned by user");

        // harm 1: soulbound mint reverted, token 2 never came into existence
        assertEq(e.soulboundMintBlocked(), 1, "soulbound mint must be blocked");
        assertEq(nft.rawOwnerOf(2), address(0), "soulbound token 2 must not exist");

        // harm 2: soulbound burn reverted, token 3 permanently stuck with the user
        assertEq(e.soulboundBurnBlocked(), 1, "soulbound burn must be blocked");
        assertEq(nft.ownerOf(3), address(0xBEEF), "soulbound token 3 remains stuck");

        // DoS magnitude recorded at the SINK: 2 soulbound tokens permanently bricked
        assertEq(marker.balanceOf(SINK), 2, "DoS magnitude marker == 2");

        emit log_named_uint("soulbound tokens permanently bricked", marker.balanceOf(SINK));
    }
}
