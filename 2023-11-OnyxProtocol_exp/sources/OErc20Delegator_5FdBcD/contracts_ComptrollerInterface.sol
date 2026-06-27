pragma solidity ^0.5.16;


contract ComptrollerInterface {
    /// @notice Indicator that this is a Comptroller contract (for inspection)
    bool public constant isComptroller = true;

    /*** Assets You Are In ***/

    function enterMarkets(address[] calldata oTokens) external returns (uint[] memory);
    function exitMarket(address oToken) external returns (uint);

    /*** Policy Hooks ***/

    function mintAllowed(address oToken, address minter, uint mintAmount) external returns (uint);
    function mintVerify(address oToken, address minter, uint mintAmount, uint mintTokens) external;

    function redeemAllowed(address oToken, address redeemer, uint redeemTokens) external returns (uint);
    function redeemVerify(address oToken, address redeemer, uint redeemAmount, uint redeemTokens) external;

    function borrowAllowed(address oToken, address borrower, uint borrowAmount) external returns (uint);
    function borrowVerify(address oToken, address borrower, uint borrowAmount) external;

    function repayBorrowAllowed(
        address oToken,
        address payer,
        address borrower,
        uint repayAmount) external returns (uint);
    function repayBorrowVerify(
        address oToken,
        address payer,
        address borrower,
        uint repayAmount,
        uint borrowerIndex) external;

    function liquidateBorrowAllowed(
        address oTokenBorrowed,
        address oTokenCollateral,
        address liquidator,
        address borrower,
        uint repayAmount) external returns (uint);
    function liquidateBorrowVerify(
        address oTokenBorrowed,
        address oTokenCollateral,
        address liquidator,
        address borrower,
        uint repayAmount,
        uint seizeTokens) external;

    function seizeAllowed(
        address oTokenCollateral,
        address oTokenBorrowed,
        address liquidator,
        address borrower,
        uint seizeTokens) external returns (uint);
    function seizeVerify(
        address oTokenCollateral,
        address oTokenBorrowed,
        address liquidator,
        address borrower,
        uint seizeTokens) external;

    function transferAllowed(address oToken, address src, address dst, uint transferTokens) external returns (uint);
    function transferVerify(address oToken, address src, address dst, uint transferTokens) external;

    /*** Liquidity/Liquidation Calculations ***/

    function liquidateCalculateSeizeTokens(
        address oTokenBorrowed,
        address oTokenCollateral,
        uint repayAmount) external view returns (uint, uint);

}
