pragma solidity >=0.7.0 <0.9.0;
pragma experimental ABIEncoderV2;

import {IBazaarVault} from "./IBazaarVault.sol";

interface IBazaarLBP {
    function getPoolId() external view returns (bytes32);

    function getTotalAccruedSwapFees() external view returns (uint256[] memory);

    //// SWAP ////

    struct SwapRequest {
        IBazaarVault.SwapKind kind;
        address tokenIn;
        address tokenOut;
        uint256 amount;
        // Misc data
        bytes32 poolId;
        uint256 lastChangeBlock;
        address from;
        address to;
        bytes userData;
    }

    function onSwap(SwapRequest memory swapRequest, uint256 currentBalanceTokenIn, uint256 currentBalanceTokenOut)
        external
        returns (uint256 amount);

    function querySwap(SwapRequest memory swapRequest, uint256 currentBalanceTokenIn, uint256 currentBalanceTokenOut)
        external
        view
        returns (uint256 amount);

    //// Join ////

    function onJoinPool(
        bytes32 poolId,
        address sender,
        address recipient,
        uint256[] memory balances,
        uint256 lastChangeBlock,
        uint256 protocolSwapFeePercentage,
        bytes memory userData
    ) external returns (uint256[] memory amountsIn, uint256[] memory dueProtocolFeeAmounts);

    //// Exit ////

    function onExitPool(
        bytes32 poolId,
        address sender,
        address recipient,
        uint256[] memory balances,
        uint256 lastChangeBlock,
        uint256 protocolSwapFeePercentage,
        bytes memory userData
    ) external returns (uint256[] memory amountsOut, uint256[] memory dueProtocolFeeAmounts);
}
