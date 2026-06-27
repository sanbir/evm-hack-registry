pragma solidity 0.8.20;

import {IModularSwapRouter} from "./modularSwapRouter/IModularSwapRouter.sol";

interface IMarginTrading {

    // ONLY MANAGER_ROLE FUNCTIONS //

    /**
     * @notice Updates the modular swap router.
     * @param newModularSwapRouter The address of the new modular swap router.
     */
    function setModularSwapRouter(IModularSwapRouter newModularSwapRouter) external;

    /**
     * @notice Updates the red coefficient.
     * @param newRedCoeff The new red coefficient.
     */
    function setRedCoeff(uint newRedCoeff) external;

    // PUBLIC FUNCTIONS //

    function BASE_TOKEN() external view returns (address BASE_TOKEN);

    /**
     * @notice Calculates the total value of a margin account.
     * @param marginAccountID The ID of the margin account.
     * @return marginAccountValue The total value of the margin account.
     */
    function calculateMarginAccountValue(uint marginAccountID) external returns (uint marginAccountValue);

    /**
     * @notice Calculates the total debt with accrued interest for a margin account.
     * @param marginAccountID The ID of the margin account.
     * @return debtSizeInUSDC The total debt with accrued interest in USDC.
     */
    function calculateDebtWithAccruedInterest(uint marginAccountID) external returns (uint debtSizeInUSDC);

    /**
     * @notice Gets the margin account ratio.
     * @param marginAccountID The ID of the margin account.
     * @return The margin account ratio.
     */
    function getMarginAccountRatio(uint marginAccountID) external returns(uint);

    /**
     * @dev Prepares ERC20 and ERC721 token parameters for a given margin account.
     * @param marginAccountID The ID of the margin account.
     * @param baseToken The base token address.
     * @return erc20Params The array of ERC20 position info.
     * @return erc721Params The array of ERC721 position info.
     */    
    function prepareTokensParams(uint marginAccountID, address baseToken) external view returns (
        IModularSwapRouter.ERC20PositionInfo[] memory erc20Params, 
        IModularSwapRouter.ERC721PositionInfo[] memory erc721Params
    );
    
    /**
     * @dev Prepares ERC20 token parameters based on debt for a given margin account.
     * @param marginAccountID The ID of the margin account.
     * @param baseToken The base token address.
     * @return erc20Params The array of ERC20 position info based on debt.
     * @return erc721Params An empty array of ERC721 position info.
     */    
    function prepareTokensParamsByDebt(uint marginAccountID, address baseToken) external view returns (
        IModularSwapRouter.ERC20PositionInfo[] memory erc20Params, 
        IModularSwapRouter.ERC721PositionInfo[] memory erc721Params
    );

    function redCoeff() external returns (uint redCoeff);

    // ONLY APPROVE OR OWNER FUNCTIONS //

    /**
     * @notice Provides ERC20 tokens as collateral to a margin account.
     * @param marginAccountID The ID of the margin account.
     * @param token The address of the ERC20 token.
     * @param amount The amount of tokens to provide.
     */
    function provideERC20(uint marginAccountID, address token, uint amount) external;

    /**
     * @notice Provides an ERC721 token as collateral to a margin account.
     * @param marginAccountID The ID of the margin account.
     * @param token The address of the ERC721 token.
     * @param collateralTokenID The ID of the ERC721 token to provide.
     */
    function provideERC721(uint marginAccountID, address token, uint collateralTokenID) external;

    /**
     * @notice Withdraws ERC20 tokens from a margin account.
     * @param marginAccountID The ID of the margin account.
     * @param token The address of the ERC20 token.
     * @param amount The amount of tokens to withdraw.
     */
    function withdrawERC20(uint marginAccountID, address token, uint amount) external;

    /**
     * @notice Withdraws an ERC721 token from a margin account.
     * @param marginAccountID The ID of the margin account.
     * @param token The address of the ERC721 token.
     * @param value The value of the ERC721 token to withdraw.
     */
    function withdrawERC721(uint marginAccountID, address token, uint value) external;

    /**
     * @notice Borrows tokens using the margin account as collateral.
     * @param marginAccountID The ID of the margin account.
     * @param token The address of the token to borrow.
     * @param amount The amount of tokens to borrow.
     */
    function borrow(uint marginAccountID, address token, uint amount) external;

    /**
     * @notice Repays the borrowed tokens for a margin account.
     * @param marginAccountID The ID of the margin account.
     * @param token The address of the token to repay.
     * @param amount The amount of tokens to repay.
     */
    function repay(uint marginAccountID, address token, uint amount) external;

    /**
     * @notice Swaps tokens within a margin account.
     * @param marginAccountID The ID of the margin account.
     * @param tokenIn The address of the input token.
     * @param tokenOut The address of the output token.
     * @param amountIn The amount of input tokens to swap.
     * @param amountOutMinimum The minimum amount of output tokens expected.
     */
    function swap(uint marginAccountID, address tokenIn, address tokenOut, uint amountIn, uint amountOutMinimum) external;

    /**
     * @notice This function allows the owner or approved user of a margin account to exercise a collateral position.
     * @param marginAccountID The ID of the margin account.
     * @param token The address of the collateral token to be exercised.
     * @param collateralTokenID The ID of the collateral token to be exercised.
     */
    function exercise(uint marginAccountID, address token, uint collateralTokenID) external;

    // ONLY LIQUIDATOR_ROLE FUNCTIONS //

    /**
     * @notice Liquidates a margin account if the account ratio is below the red coefficient.
     * @param marginAccountID The ID of the margin account to liquidate.
     */
    function liquidate(uint marginAccountID) external;

    // EVENTS //

    /**
     * @notice Emitted when the modular swap router is updated.
     * @param newModularSwapRouter The address of the new modular swap router.
     */
    event UpdateModularSwapRouter(
        address newModularSwapRouter
    );

    /**
     * @notice Emitted when the red coefficient is updated.
     * @param newRedCoeff The new red coefficient value.
     */
    event UpdateRedCoeff(
        uint newRedCoeff
    );

    /**
     * @notice Emitted when the yellow coefficient is updated.
     * @param newYellowCoeff The new yellow coefficient value.
     */
    event UpdateYellowCoeff(
        uint newYellowCoeff
    );

    /**
     * @notice Emitted when ERC20 tokens are provided as collateral to a margin account.
     * @param marginAccountID The ID of the margin account.
     * @param sender The address of the sender providing the collateral.
     * @param token The address of the ERC20 token.
     * @param amount The amount of tokens provided.
     */
    event ProvideERC20(
        uint indexed marginAccountID, 
        address indexed sender,
        address indexed token, 
        uint amount
    );

    /**
     * @notice Emitted when an ERC721 token is provided as collateral to a margin account.
     * @param marginAccountID The ID of the margin account.
     * @param sender The address of the sender providing the collateral.
     * @param token The address of the ERC721 token.
     * @param collateralTokenID The ID of the ERC721 token provided.
     */
    event ProvideERC721(
        uint indexed marginAccountID, 
        address indexed sender,
        address indexed token, 
        uint collateralTokenID
    );

    /**
     * @notice Emitted when ERC20 tokens are withdrawn from a margin account.
     * @param marginAccountID The ID of the margin account.
     * @param sender The address of the sender withdrawing the collateral.
     * @param token The address of the ERC20 token.
     * @param amount The amount of tokens withdrawn.
     */
    event WithdrawERC20(
        uint indexed marginAccountID, 
        address indexed sender,
        address indexed token, 
        uint amount
    );

    /**
     * @notice Emitted when an ERC721 token is withdrawn from a margin account.
     * @param marginAccountID The ID of the margin account.
     * @param sender The address of the sender withdrawing the collateral.
     * @param token The address of the ERC721 token.
     * @param value The value of the ERC721 token withdrawn.
     */
    event WithdrawERC721(
        uint indexed marginAccountID, 
        address indexed sender,
        address indexed token, 
        uint value
    );

    /**
     * @notice Emitted when tokens are borrowed using a margin account as collateral.
     * @param marginAccountID The ID of the margin account.
     * @param sender The address of the borrower.
     * @param token The address of the borrowed token.
     * @param amount The amount of tokens borrowed.
     */
    event Borrow(
        uint indexed marginAccountID, 
        address indexed sender,
        address indexed token, 
        uint amount
    );

    /**
     * @notice Emitted when borrowed tokens are repaid to a margin account.
     * @param marginAccountID The ID of the margin account.
     * @param sender The address of the sender repaying the debt.
     * @param token The address of the token being repaid.
     * @param amount The amount of tokens repaid.
     */
    event Repay(
        uint indexed marginAccountID, 
        address indexed sender,
        address indexed token, 
        uint amount
    );

    /**
     * @notice Emitted when a token swap is executed within a margin account.
     * @param marginAccountID The ID of the margin account.
     * @param swapID The unique ID of the swap operation.
     * @param tokenIn The address of the input token.
     * @param tokenOut The address of the output token.
     * @param amountIn The amount of input tokens swapped.
     */
    event Swap(
        uint indexed marginAccountID, 
        uint indexed swapID,
        address tokenIn, 
        address tokenOut, 
        uint amountIn
    );

    /**
     * @notice Emitted when a margin account is liquidated.
     * @param marginAccountID The ID of the margin account being liquidated.
     */
    event Liquidate(
        uint indexed marginAccountID,
        address liquidator
    );

    /**
     * @dev Emitted when a collateral position is exercised in a margin account.
     * @param marginAccountID The ID of the margin account where the exercise occurred.
     * @param tokenIn The address of the collateral token being exercised.
     * @param tokenOut The address of the base token received in exchange.
     * @param value The value of the collateral token being exercised.
     */
    event Exercise(
        uint indexed marginAccountID, 
        address tokenIn, 
        address tokenOut, 
        uint value
    );
}
