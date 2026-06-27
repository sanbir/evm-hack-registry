pragma solidity ^0.5.16;

interface IBProtocol {
    function canLiquidate(
        address cTokenBorrowed,
        address cTokenCollateral,
        uint repayAmount
    )
    external
    view
    returns(bool);
}
