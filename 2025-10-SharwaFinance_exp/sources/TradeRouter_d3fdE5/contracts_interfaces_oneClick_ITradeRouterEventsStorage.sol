pragma solidity 0.8.20;

interface ITradeRouterEventsStorage {
    function emitSettlePositions(uint marginAccountID) external;
    function emitIncreaseLongPosition(uint marginAccountID, address token, uint amount) external;
    function emitIncreaseShortPosition(uint marginAccountID, address token, uint amount) external;
    function emitDecreaseLongPosition(uint marginAccountID, address token, uint amount) external;
    function emitDecreaseShortPosition(uint marginAccountID, address token, uint amount) external;
}