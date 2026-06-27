pragma solidity ^0.5.16;

contract ComptrollerExInterface {
    function liquidateCalculateSeizeTokensEx(
        address oTokenBorrowed,
        address oTokenExCollateral,
        uint repayAmount) external view returns (uint, uint, uint);

    function getLiquidationSeizeIndexes() external view returns (uint[] memory) {}
}

interface ILiquidationProxy {
    function isNFTLiquidation() external view returns(bool);
    function extraRepayAmount() external view returns(uint);
    function seizeIndexes() external view returns(uint[] memory);
}
