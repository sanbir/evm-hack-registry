// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "./38504-the-bridging-process-will-revert-if-the-collection-is-matche.sol";

/*//////////////////////////////////////////////////////////////
    ArkProject NFT Bridge — The bridging process will revert if the
    collection is matched on the destination chain and not matched
    on the source chain. Finding #38504 (Codehawks, pwnforce) — HIGH.

    Drives the synthetic Exploit and re-asserts the harm directly,
    contrasted against a control where the L1 mapping IS correctly
    populated and the withdrawal succeeds normally.
//////////////////////////////////////////////////////////////*/
contract ArkBridge38504Test is Test {
    Exploit exploit;

    function setUp() public {
        exploit = new Exploit();
    }

    /// @notice Control: the FIRST-EVER withdrawal of a brand-new collection
    ///         (request carries l1Req = address(0), only the L2 address is
    ///         known) hits the function's "first token of the collection"
    ///         branch, which returns successfully with no mapping needed.
    ///         This isolates the bug to the SECOND branch's missing-mapping
    ///         state specifically, not the verification mechanism itself.
    function test_control_firstTimeBridge_withdrawSucceeds() public {
        MockERC721 collection = new MockERC721();
        L1BridgeLike bridge = new L1BridgeLike(collection);
        address to = address(0xBEEF);

        collection.mint(address(bridge), 1);

        // l1Req = address(0): the request only carries the L2-side address,
        // matching the "first token of the collection" happy path — no L1
        // mapping is required, so this never touches the missing-mapping
        // branch that the attack scenario below exercises.
        address verified = bridge.withdrawTokens(address(0), 0xC0FFEE, 1, to);
        assertEq(verified, address(0));
        assertEq(collection.ownerOf(1), to);
    }

    /// @notice HARM: the collection's pairing was only ever recorded on L2
    ///         (matching the finding's scenario exactly) — L1Bridge's own
    ///         mapping is empty. withdrawTokens reverts with
    ///         InvalidCollectionL1Address(), and the NFT stays stuck in the
    ///         bridge forever — there is no code path in this (unfixed)
    ///         version that can ever populate the missing mapping.
    function test_run_unmatchedL1Mapping_bricksWithdrawal() public {
        uint256 tokenId = exploit.TOKEN_ID();
        MockERC721 collection = exploit.collection();
        L1BridgeLike bridge = exploit.bridge();
        uint256 l2Id = exploit.COLLECTION_L2_ID();

        assertEq(collection.ownerOf(tokenId), address(bridge));

        exploit.run();

        // Direct re-assertion: the exact withdrawal call reverts.
        vm.expectRevert(L1BridgeLike.InvalidCollectionL1Address.selector);
        bridge.withdrawTokens(address(collection), l2Id, tokenId, address(0xBEEF));

        // The NFT never moved — permanently stuck in the bridge contract.
        assertEq(collection.ownerOf(tokenId), address(bridge));
    }
}
