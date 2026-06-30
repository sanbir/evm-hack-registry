// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

interface IERC314 {
    function name() external view returns (string memory);

    function symbol() external view returns (string memory);

    function totalSupply() external view returns (uint256);

    function liquidityToken() external view returns (address);

    function owner() external view returns (address);

    function price0CumulativeLast() external view returns (uint256);

    function price1CumulativeLast() external view returns (uint256);

    function blockTimestampLast() external view returns (uint32);

    function addLiquidity(
        uint256 amountToken,
        address recipient,
        uint256 deadline
    ) external payable returns (uint256 liquidity);

    function removeLiquidity(
        uint256 amount,
        address recipient,
        uint256 deadline
    ) external returns (uint256 nativeAmount, uint256 tokenAmount);

    function swapNativeToToken(
        uint256 minimumTokensOut,
        uint256 deadline
    ) external payable returns (uint256[] memory amounts);

    function swapTokenToNative(
        uint256 tokensSold,
        uint256 minimumNativeOut,
        uint256 deadline
    ) external returns (uint256[] memory amounts);

    function flashSwap(
        address recipient,
        uint256 amountNativeOut,
        uint256 amountTokenOut,
        bytes calldata data
    ) external;

    function getAmountOut(
        uint256 inputAmount,
        uint256 inputReserve,
        uint256 outputReserve
    )
        external
        view
        returns (uint256 outputAmount, uint256 factoryFee, uint256 tradingFee);

    function getAmountIn(
        uint256 outputAmount,
        uint256 inputReserve,
        uint256 outputReserve
    ) external view returns (uint256 inputAmount);

    function getTokensInContract() external view returns (uint256);

    function getReserves()
        external
        view
        returns (uint256 amountNative, uint256 amountToken);

    function getAmountsForLP(
        uint256 amount
    ) external view returns (uint256 nativeAmount, uint256 tokenAmount);

    function setFeeCollector(address feeCollector) external;

    function setTradingFeeRate(uint256 feeRate) external;

    function setTradingEnabled() external;

    function setMaxWalletExempt(
        address addressToChange,
        bool isExempt
    ) external;

    function setMaxWalletPercent(uint256 maxWalletPercent_) external;

    function setMaxWalletEnabled(bool enabled) external;

    function setMetadataURI(string memory newURI) external;

    function claimFees() external;

    function transferOwnership(address newOwner) external;

    function renounceOwnership() external;
}
