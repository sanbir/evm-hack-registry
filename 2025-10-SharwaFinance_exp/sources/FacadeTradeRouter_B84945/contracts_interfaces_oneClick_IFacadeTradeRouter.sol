pragma solidity 0.8.20;

interface IFacadeTradeRouter {
    function increaseLongPosition(
        uint marginAccountID, 
        address token,
        uint amount
    ) external;

    function increaseShortPosition(
        uint marginAccountID, 
        address token,
        uint amount
    ) external;

    function decreaseLongPosition(
        uint marginAccountID, 
        address token,
        uint amount
    ) external;

    function decreaseShortPosition(
        uint marginAccountID, 
        address token,
        uint amount
    ) external;

    function settlePositions(
        uint marginAccountID
    ) external;
}