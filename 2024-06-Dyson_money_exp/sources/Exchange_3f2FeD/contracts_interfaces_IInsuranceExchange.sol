pragma solidity ^0.8.0;

interface IInsuranceExchange {

    struct SwapData {
        address inputTokenAddress;
        address outputTokenAddress;
        uint256 amountIn;
        bytes data;
    }

    struct InputMint {
        uint256 amount;
    }

    struct InputRedeem {
        uint256 amount;
    }

    function mint(InputMint calldata input) external;

    function redeem(InputRedeem calldata input) external;

    function payout() external;

    function premium(SwapData memory swapData, uint256 premiumAmount) external;

    function compensate(SwapData memory swapData, uint256 assetAmount, address to) external;

    function requestWithdraw() external;

    function checkWithdraw() external;


}
