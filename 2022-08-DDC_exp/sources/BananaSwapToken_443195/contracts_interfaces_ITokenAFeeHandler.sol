//SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;
import "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import "./IERC20.sol";

interface ITokenAFeeHandler is IERC20{
    enum FeeType {
        nodeRewardRatio, //0 Node reward
        dividendRatio, //1 Mining with coins
        marketingRatio, //2 marketing
        destroyRatio, //3 destroy
        lpRewardRatio, //4 Liquidity Rewards
        reflowRatio, //5 reflow casting pool
        nftRatio, //6 NFT mining
        ecologyRatio, //7 Ecological construction
        repurchaseDestroy, //8 Repurchase and destroy
        reduceRatio, //9 Sell the remainder after deducting the slippage fee and destroy it
        sellLimitRatio //10 Sell Limit
    }

    enum ActionType {
        Buy, //0
        Sell, //1
        AddLiquid, //2
        RemoveLiquid, //3
        Transfer, //4
        SellReduce//5 Handle the sales repurchase function in the pool, and rebate liquidity.
    }

    struct FeeConfig {
        uint256 feeRatio;
        bool needHandle; // 0-transfer to target; 1-transfer target and handle
        address feeHandler;
    }

    struct InsuredConfig{
        uint32 start;
        uint32 end;
        uint ratio;
    }

    struct TradingOperationConfig {
        ActionType actionType;
        uint256 totalFeeRatio;
        mapping(uint256 => FeeConfig) handleConfig;
        EnumerableSet.UintSet rewardTypeSet;
    }

    struct LiquidityLockConfig {
        bool openLockLiquid;
        uint lockLiquidDuration;
        address lpTimeLock;
    }

    function setFeeConfig(
        ActionType _tradingType,
        FeeType _rewardType,
        FeeConfig memory _config,
        bool opt
    ) external;

 

    function getFeeConfig(ActionType _tradingType, FeeType _rewardType)
        external
        view
        returns (FeeConfig memory feeConfig);

    function getBase() external view returns (uint256);

    function handleDeductFee(ActionType actionType,uint256 feeAmount,address from,address user) external;

    function calDeductFee(ActionType actionType, uint256 inputAmount)
        external
        view
        returns (uint256 leftAmount);

    function calAddFee(ActionType actionType, uint256 inputAmount)
        external
        view
        returns (uint256 addAmount);

    function validateBk(address buyAddress) external view;

    function reflowDistributeFee(ActionType actionType) external;

    function getReduceThreshold() external view returns (uint);

    function getLiquidityLockConfig() external view returns(LiquidityLockConfig memory config);
    function setLiquidityLockConfig(LiquidityLockConfig memory config) external;
    // function handleLiquidDeductFee( ActionType actionType, uint256 feeAmount, address from ) external;

    function transferFromFee(
        address from,
        address to,
        uint256 amount,
        ITokenAFeeHandler.ActionType actionType,
        address user
    ) external returns (uint256 deductFeeLeftAmount);

    function transferFee(address to, uint256 amount,ITokenAFeeHandler.ActionType actionType,address user) external returns (uint256 deductFeeLeftAmount);
}
