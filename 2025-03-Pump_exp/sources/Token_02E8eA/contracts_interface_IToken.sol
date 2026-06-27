// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.20;

interface IToken {
    error TokenNotListed();
    error TokenListed();
    error IPShareNotCreated();
    error TokenInitialized();
    error ClaimOrderExist();
    error InvalidSignature();
    error InvalidClaimAmount();
    error OutOfSlippage();
    error InsufficientFund();
    error RefundFail();
    error CostFeeFail();
    error DustIssue();

    event Trade(
        address indexed buyer,
        address indexed sellsman,
        bool isBuy,
        uint256 tokenAmount,
        uint256 ethAmount,
        uint256 tiptagFee,
        uint256 sellsmanFee
    );
    event TokenListedToDex(address indexed pair);
    
    function listed() external view returns (bool);

    function getIPShare() external view returns (address);
}