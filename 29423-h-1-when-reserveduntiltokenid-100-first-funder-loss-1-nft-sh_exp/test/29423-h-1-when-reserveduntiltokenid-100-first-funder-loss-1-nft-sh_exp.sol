// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "./29423-h-1-when-reserveduntiltokenid-100-first-funder-loss-1-nft-sh.sol";

/*//////////////////////////////////////////////////////////////
    Nouns Builder — when reservedUntilTokenId > 100, first founder loses 1%
    NFT (H-1, #29423)

    `_addFounders` seeds `baseTokenId = reservedUntilTokenId` with no modulo.
    Since every real token id is reduced via `% 100` before lookup, a
    `reservedUntilTokenId > 100` wastes the founder's FIRST scheduled slot on
    an id that can never be reached.

    - test_exploit: drives the cheatcode-free Exploit end to end, then
      re-asserts the harm (founder receives 9 of 10 promised slots)
      independently.
    - test_lossFirst_standalone: standalone rebuild mirroring the finding's
      own `test_lossFirst`-style assertion on `tokenRecipient(200)`.
    - test_control_reservedUnder100_noLoss: control — with
      `reservedUntilTokenId <= 100`, the founder receives all 10 promised
      slots, isolating the bug to the >100 case.
//////////////////////////////////////////////////////////////*/
contract FirstFounderLossTest is Test {
    function test_exploit() public {
        Exploit e = new Exploit();
        e.run();

        assertTrue(e.slot200SetForFounder(), "the wasted slot 200 was indeed scheduled for the founder");
        assertEq(e.reachableSlotsForFounder(), 9, "founder should only reach 9 of the 10 promised slots");
    }

    function test_lossFirst_standalone() public {
        Token token = new Token();
        address founder = address(0xF00D);

        Token.FounderParams[] memory founders = new Token.FounderParams[](1);
        founders[0] = Token.FounderParams({wallet: founder, percent: 10, vestExpiry: type(uint32).max});
        token.addFounders(founders, 200);

        (address wallet, , ) = token.tokenRecipient(200);
        assertEq(wallet, founder, "tokenRecipient[200] is scheduled for the founder");

        // But it is unreachable: no real token id (0-99) maps to it, and
        // slot 0 (200 % 100) was never actually written for the founder.
        (address wallet0, , ) = token.tokenRecipient(0);
        assertEq(wallet0, address(0), "slot 0 was never written -- 200's schedule is wasted");
    }

    /// @notice Control: when reservedUntilTokenId <= 100 (e.g. 0), the founder
    ///         receives all 10 of their promised slots — no loss.
    function test_control_reservedUnder100_noLoss() public {
        Token token = new Token();
        address founder = address(0xF00D);

        Token.FounderParams[] memory founders = new Token.FounderParams[](1);
        founders[0] = Token.FounderParams({wallet: founder, percent: 10, vestExpiry: type(uint32).max});
        token.addFounders(founders, 0);

        uint256 count;
        for (uint256 id; id < 100; id++) {
            (address w, , ) = token.tokenRecipient(id);
            if (w == founder) count++;
        }
        assertEq(count, 10, "control: founder receives all 10 promised slots when reservedUntilTokenId <= 100");
    }
}
