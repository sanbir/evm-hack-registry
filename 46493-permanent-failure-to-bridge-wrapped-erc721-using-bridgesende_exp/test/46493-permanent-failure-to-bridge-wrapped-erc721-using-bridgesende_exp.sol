// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "./46493-permanent-failure-to-bridge-wrapped-erc721-using-bridgesende.sol";

/*//////////////////////////////////////////////////////////////////////////
    Sweep n Flip Bridge — wrap reverse-bridge permanent failure (#46493)
//////////////////////////////////////////////////////////////////////////*/
contract BridgeWrappedERC721Test is Test {
    function test_exploit() public {
        Exploit e = new Exploit();
        e.run();

        assertTrue(e.bridge().isLocked(address(e.originNft()), 2), "origin still locked");
        assertEq(e.wrappedNft().ownerOf(2), address(e), "wrap not consumed");
        assertEq(e.wrappedNft().originAddress(), e.ORIGIN_ON_DEST());
        assertEq(e.ORIGIN_ON_DEST().code.length, 0, "origin codeless on dest");
    }

    /// @notice Control: bridging the ORIGIN collection (metadata lives here) succeeds.
    function test_originBridgeWorks() public {
        Bridge bridge = new Bridge();
        MockERC721 origin = new MockERC721();
        origin.mint(address(this), 1, "ipfs://1");
        origin.setApprovalForAll(address(bridge), true);

        uint256[] memory ids = new uint256[](1);
        ids[0] = 1;
        bridge.sendERC721UsingNative{value: 0}(137, address(origin), ids);

        assertTrue(bridge.lastSendSucceeded());
        assertEq(origin.ownerOf(1), address(bridge));
    }
}
