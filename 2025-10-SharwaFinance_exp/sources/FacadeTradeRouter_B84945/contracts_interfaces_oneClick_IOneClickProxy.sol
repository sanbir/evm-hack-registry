pragma solidity 0.8.20;

interface IOneClickProxy {
    function changePosition(
        uint marginAccountID,
        address positionToken,
        int256 positionSize,
        int256 collateralAmount
    ) external;

    function provideERC20(
        uint marginAccountID,
        address token,
        uint amount
    ) external;

    function provideERC721(
        uint marginAccountID,
        address token,
        uint collateralTokenID
    ) external;

    function withdrawERC20(
        uint marginAccountID,
        address token,
        uint amount
    ) external;

    function withdrawERC721(
        uint marginAccountID,
        address token,
        uint value
    ) external;

    function borrow(uint marginAccountID, address token, uint amount) external;

    function repay(uint marginAccountID, address token, uint amount) external;

    function swap(
        uint marginAccountID,
        address tokenIn,
        address tokenOut,
        uint amountIn,
        uint amountOutMinimum
    ) external;

    function exercise(
        uint marginAccountID,
        address token,
        uint collateralTokenID
    ) external;

    function executeOrder(uint idOrder) external;

    function deleteOrder(uint idOrder) external;

    function getPosition(
        uint marginAccountID,
        address positionToken
    ) external view returns (int256, int256, uint256, bool, bool);

    function getOptionOwner(
        uint marginAccountID,
        address token
    ) external view returns (uint);

    function getPositionTokens() external view returns (address[] memory);
}
