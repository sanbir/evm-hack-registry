// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "./41090-h-04-forced-endtime-extension-in-updateartsettings-allows-at.sol";

/*//////////////////////////////////////////////////////////////
    Phi -- Forced endTime extension in updateArtSettings (H-04, #41090)

    After a mint event ends, updateArtSettings forces endTime_ >= now, which
    reopens minting for the current block. An attacker snipes residual supply.

    - test_exploit: drives the cheatcode-free Exploit end to end.
    - test_cannotUpdateWithPastEndTime: control — EndTimeInPast still enforced.
//////////////////////////////////////////////////////////////////////////*/
contract PhiForcedEndTimeExtensionTest is Test {
    function test_exploit() public {
        Exploit e = new Exploit();
        e.run();

        assertEq(e.artToken().balanceOf(e.ATTACKER(), e.ART_ID()), e.EXTRA_MINT(), "residual sniped");
        assertEq(e.factory().numberMintedOf(e.ART_ID()), e.MAX_SUPPLY(), "max supply hit");
    }

    function test_cannotUpdateWithPastEndTime() public {
        MockArt art = new MockArt();
        PhiFactory factory = new PhiFactory(art);
        factory.seedEndedArt(address(this), address(this), 100, 10, 0, "ipfs://x");

        vm.expectRevert(PhiFactory.EndTimeInPast.selector);
        factory.updateArtSettings(1, "ipfs://y", address(this), 100, 0, 0, 0, false);
    }
}
