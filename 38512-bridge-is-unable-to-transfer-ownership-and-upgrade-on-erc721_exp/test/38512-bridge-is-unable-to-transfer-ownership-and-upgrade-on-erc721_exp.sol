// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "forge-std/console2.sol";
import {
    Exploit,
    Starklane,
    ERC721Bridgeable
} from "./38512-bridge-is-unable-to-transfer-ownership-and-upgrade-on-erc721.sol";

/// Control bridge: the L2 admin forwarder, present on L1.
contract StarklaneFixed {
    ERC721Bridgeable public collection;
    address public owner;

    constructor() {
        owner = msg.sender;
        collection = new ERC721Bridgeable();
        collection.initialize(abi.encode("Ark", "ARK"));
    }

    modifier onlyOwner() {
        require(msg.sender == owner, "admin");
        _;
    }

    function collectionTransferOwnership(address c, address newOwner) external onlyOwner {
        ERC721Bridgeable(c).transferOwnership(newOwner);
    }

    function mintToSelf(uint256 id) external onlyOwner {
        collection.mintFromBridge(address(this), id);
    }
}

contract Finding38512Test is Test {
    function test_transfer_reverts_and_old_owner_mints() public {
        Exploit e = new Exploit();
        e.run();

        assertTrue(e.transferReverted(), "transfer reverted");
        assertEq(e.ownerAfter(), address(e.bridge()), "owner unchanged");
        assertEq(e.mintedToOldOwner(), e.N(), "5 tokens minted to the old owner");
        assertEq(e.collection().balanceOf(address(e.bridge())), 5, "balance");
        assertEq(e.collection().ownerOf(4), address(e.bridge()), "token 4");
        console2.log("transfer reverted", e.transferReverted() ? 1 : 0);
        console2.log("owner is still bridge", e.ownerAfter() == address(e.bridge()) ? 1 : 0);
        console2.log("minted to old owner", e.mintedToOldOwner());
    }

    function test_control_transfer_blocks_old_mint() public {
        StarklaneFixed oldBridge = new StarklaneFixed();
        address replacement = address(0xB0B);
        oldBridge.collectionTransferOwnership(address(oldBridge.collection()), replacement);

        assertEq(oldBridge.collection().owner(), replacement, "ownership moved");
        (bool minted,) = address(oldBridge).call(abi.encodeWithSignature("mintToSelf(uint256)", 0));
        assertFalse(minted, "old owner must not mint");
        assertEq(oldBridge.collection().balanceOf(address(oldBridge)), 0, "old owner balance");
        console2.log("control owner moved", oldBridge.collection().owner() == replacement ? 1 : 0);
        console2.log("control old mint succeeded", minted ? 1 : 0);
        console2.log("control old balance", oldBridge.collection().balanceOf(address(oldBridge)));
    }
}
