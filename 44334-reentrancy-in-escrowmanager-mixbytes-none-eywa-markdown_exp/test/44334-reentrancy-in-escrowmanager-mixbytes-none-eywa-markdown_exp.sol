// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import "forge-std/Test.sol";
import {Exploit, Collection, EscrowManager} from
    "./44334-reentrancy-in-escrowmanager-mixbytes-none-eywa-markdown.sol";

contract NftHolder {
    function onERC721Received(address, address, uint256, bytes calldata) external pure returns (bytes4) {
        return this.onERC721Received.selector;
    }

    function deboostOnce(EscrowManager escrow) external {
        uint256[] memory ids = new uint256[](1);
        ids[0] = 7;
        escrow.deboost(7, ids);
    }
}

contract Finding44334Test is Test {
    function test_duplicate_deboost_inflates_votes() public {
        Exploit e = new Exploit();
        e.run();
        assertEq(e.votesBefore(), 100 ether, "before");
        assertEq(e.votesAfter(), 10_000 ether, "after");
        assertEq(e.collection().ownerOf(1), address(e.escrow()), "nft back in escrow");
        (, uint256 coverage,) = e.escrow().locks(1);
        assertEq(coverage, 0, "coverage zero");
    }

    function test_control_single_id_keeps_coverage() public {
        Collection collection = new Collection();
        EscrowManager escrow = new EscrowManager(collection);
        NftHolder holder = new NftHolder();
        collection.mint(address(escrow), 7);
        escrow.setBooster(7, 25);
        escrow.openLock(address(holder), 7, 100 ether, 100);
        uint256 beforeVotes = escrow.votes(address(holder));
        holder.deboostOnce(escrow);
        (, uint256 coverage,) = escrow.locks(7);
        assertEq(beforeVotes, 100 ether, "start");
        assertEq(coverage, 75, "one booster removed");
        assertLt(escrow.votes(address(holder)), 200 ether, "no 100x jump");
        assertEq(collection.ownerOf(7), address(holder), "nft left the escrow");
    }
}
