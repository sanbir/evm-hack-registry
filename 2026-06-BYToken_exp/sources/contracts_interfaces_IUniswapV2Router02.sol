// SPDX-License-Identifier: MIT
pragma solidity >=0.6.2;

import "./IUniswapV2Router01.sol";

/**
 * @title IUniswapV2Router02
 * @notice Router02 扩展接口，支持 fee-on-transfer token。
 * @dev BY/BYC 有卖出税逻辑，相关换币应优先使用 SupportingFeeOnTransferTokens 版本。
 */
interface IUniswapV2Router02 is IUniswapV2Router01 {
    /// @notice 移除 ERC20/BNB 流动性，兼容转账扣税 token。
    function removeLiquidityETHSupportingFeeOnTransferTokens(
        address token,
        uint liquidity,
        uint amountTokenMin,
        uint amountETHMin,
        address to,
        uint deadline
    ) external returns (uint amountETH);

    /// @notice permit 授权后移除 ERC20/BNB 流动性，兼容转账扣税 token。
    function removeLiquidityETHWithPermitSupportingFeeOnTransferTokens(
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
    ) external returns (uint amountETH);

    /// @notice 固定输入 token 换 token，兼容转账扣税 token。
    function swapExactTokensForTokensSupportingFeeOnTransferTokens(
        uint amountIn,
        uint amountOutMin,
        address[] calldata path,
        address to,
        uint deadline
    ) external;

    /// @notice 固定输入 BNB 换 token，兼容转账扣税 token。
    function swapExactETHForTokensSupportingFeeOnTransferTokens(
        uint amountOutMin,
        address[] calldata path,
        address to,
        uint deadline
    ) external payable;

    /// @notice 固定输入 token 换 BNB，兼容转账扣税 token。
    function swapExactTokensForETHSupportingFeeOnTransferTokens(
        uint amountIn,
        uint amountOutMin,
        address[] calldata path,
        address to,
        uint deadline
    ) external;
}
