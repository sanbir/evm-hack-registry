// SPDX-License-Identifier: MIT
pragma solidity >=0.6.2;

/**
 * @title IUniswapV2Router01
 * @notice Pancake/Uniswap V2 Router01 标准接口。
 * @dev 项目通过该接口完成报价、换币、加流动性、移除流动性；滑点保护由调用方传入 min 参数。
 */
interface IUniswapV2Router01 {
    /// @notice 工厂地址。
    function factory() external pure returns (address);
    /// @notice WBNB/WETH 地址。
    function WETH() external pure returns (address);

    /// @notice 添加 ERC20/ERC20 流动性。
    function addLiquidity(
        address tokenA,
        address tokenB,
        uint amountADesired,
        uint amountBDesired,
        uint amountAMin,
        uint amountBMin,
        address to,
        uint deadline
    ) external returns (uint amountA, uint amountB, uint liquidity);

    /// @notice 添加 ERC20/BNB 流动性。
    function addLiquidityETH(
        address token,
        uint amountTokenDesired,
        uint amountTokenMin,
        uint amountETHMin,
        address to,
        uint deadline
    )
        external
        payable
        returns (uint amountToken, uint amountETH, uint liquidity);

    /// @notice 移除 ERC20/ERC20 流动性。
    function removeLiquidity(
        address tokenA,
        address tokenB,
        uint liquidity,
        uint amountAMin,
        uint amountBMin,
        address to,
        uint deadline
    ) external returns (uint amountA, uint amountB);

    /// @notice 移除 ERC20/BNB 流动性。
    function removeLiquidityETH(
        address token,
        uint liquidity,
        uint amountTokenMin,
        uint amountETHMin,
        address to,
        uint deadline
    ) external returns (uint amountToken, uint amountETH);

    /// @notice 使用 permit 授权后移除 ERC20/ERC20 流动性。
    function removeLiquidityWithPermit(
        address tokenA,
        address tokenB,
        uint liquidity,
        uint amountAMin,
        uint amountBMin,
        address to,
        uint deadline,
        bool approveMax,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external returns (uint amountA, uint amountB);

    /// @notice 使用 permit 授权后移除 ERC20/BNB 流动性。
    function removeLiquidityETHWithPermit(
        address token,
        uint liquidity,
        uint amountTokenMin,
        uint amountETHMin,
        address to,
        uint deadline,
        bool approveMax,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external returns (uint amountToken, uint amountETH);

    /// @notice 固定输入 token 换 token。
    function swapExactTokensForTokens(
        uint amountIn,
        uint amountOutMin,
        address[] calldata path,
        address to,
        uint deadline
    ) external returns (uint[] memory amounts);

    /// @notice 固定输出 token 换 token。
    function swapTokensForExactTokens(
        uint amountOut,
        uint amountInMax,
        address[] calldata path,
        address to,
        uint deadline
    ) external returns (uint[] memory amounts);

    /// @notice 固定输入 BNB 换 token。
    function swapExactETHForTokens(
        uint amountOutMin,
        address[] calldata path,
        address to,
        uint deadline
    ) external payable returns (uint[] memory amounts);

    /// @notice 固定输出 BNB，用 token 支付。
    function swapTokensForExactETH(
        uint amountOut,
        uint amountInMax,
        address[] calldata path,
        address to,
        uint deadline
    ) external returns (uint[] memory amounts);

    /// @notice 固定输入 token 换 BNB。
    function swapExactTokensForETH(
        uint amountIn,
        uint amountOutMin,
        address[] calldata path,
        address to,
        uint deadline
    ) external returns (uint[] memory amounts);

    /// @notice 固定输出 token，用 BNB 支付。
    function swapETHForExactTokens(
        uint amountOut,
        address[] calldata path,
        address to,
        uint deadline
    ) external payable returns (uint[] memory amounts);

    /// @notice 按储备比例报价。
    function quote(
        uint amountA,
        uint reserveA,
        uint reserveB
    ) external pure returns (uint amountB);

    /// @notice 按恒定乘积公式计算给定输入的输出。
    function getAmountOut(
        uint amountIn,
        uint reserveIn,
        uint reserveOut
    ) external pure returns (uint amountOut);

    /// @notice 按恒定乘积公式计算给定输出需要的输入。
    function getAmountIn(
        uint amountOut,
        uint reserveIn,
        uint reserveOut
    ) external pure returns (uint amountIn);

    /// @notice 查询多跳路径的预期输出。
    function getAmountsOut(
        uint amountIn,
        address[] calldata path
    ) external view returns (uint[] memory amounts);

    /// @notice 查询多跳路径的预期输入。
    function getAmountsIn(
        uint amountOut,
        address[] calldata path
    ) external view returns (uint[] memory amounts);
}
