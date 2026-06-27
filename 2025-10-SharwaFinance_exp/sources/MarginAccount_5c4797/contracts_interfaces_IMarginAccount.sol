pragma solidity 0.8.20;

import {IModularSwapRouter} from "./modularSwapRouter/IModularSwapRouter.sol";

interface IMarginAccount {

    // VIEW FUNCTIONS //
    
    /**
     * @dev Returns an array of available ERC20 tokens.
     * @return tokensArray The array of available ERC20 tokens.
     */
    function getAvailableErc20() external view returns (address[] memory tokensArray);

    /**
     * @dev Returns an array of available ERC721 tokens.
     * @return tokensArray The array of available ERC721 tokens.
     */
    function getAvailableErc721() external view returns (address[] memory tokensArray);

    /**
     * @dev Returns an array of available tokens to liquidity pool.
     * @return tokensArray The array of available tokens to liquidity pool.
     */    
    function getAvailableTokenToLiquidityPool() external view returns (address[] memory tokensArray);

    /**
     * @dev Returns the balance of a specific ERC20 token for a given margin account.
     * @param marginAccountID The ID of the margin account.
     * @param tokenAddress The address of the ERC20 token.
     * @return The balance of the specified ERC20 token.
     */    
    function getErc20ByContract(uint marginAccountID, address tokenAddress) external view returns (uint);

    /**
     * @dev Returns the list of ERC721 token IDs for a given margin account.
     * @param marginAccountID The ID of the margin account.
     * @param tokenAddress The address of the ERC721 token.
     * @return The list of ERC721 token IDs.
     */    
    function getErc721ByContract(uint marginAccountID, address tokenAddress) external view returns (uint[] memory);

    /**
     * @dev Checks if a specific ERC721 token ID is held by a given margin account.
     * @param marginAccountID The ID of the margin account.
     * @param token The address of the ERC721 token.
     * @param value The token ID to check.
     * @return hasERC721Id True if the token ID is held by the margin account, false otherwise.
     */    
    function checkERC721tokenID(uint marginAccountID, address token, uint value) external view returns(bool hasERC721Id);

    /**
     * @dev Checks if a margin account has a sufficient ERC20 token balance.
     * @param marginAccountID The ID of the margin account.
     * @param token The address of the ERC20 token.
     * @param amount The amount to check.
     * @return currectBalance True if the margin account has a sufficient balance, false otherwise.
     */    
    function checkERC20Amount(uint marginAccountID, address token, uint amount) external view returns(bool currectBalance);

    /**
     * @dev Checks if a margin account holds a specific ERC721 token ID.
     * @param marginAccountID The ID of the margin account.
     * @param token The address of the ERC721 token.
     * @param value The token ID to check.
     * @return hasERC721Id True if the token ID is held by the margin account, false otherwise.
     */    
    function checkERC721Value(uint marginAccountID, address token, uint value) external view returns (bool hasERC721Id);

    /**
     * @dev Checks if a token has a corresponding liquidity pool.
     * @param token The address of the token.
     * @return isValid True if the token has a corresponding liquidity pool, false otherwise.
     */    
    function checkLiquidityPool(address token) external view returns (bool isValid);

    /**
     * @dev Checks if a specific ERC20 token is available.
     * @param token The address of the ERC20 token.
     * @return A boolean indicating if the ERC20 token is available.
     */
    function isAvailableErc20(address token) external view returns (bool); 

    /**
     * @dev Checks if a specific ERC721 token is available.
     * @param token The address of the ERC721 token.
     * @return A boolean indicating if the ERC721 token is available.
     */
    function isAvailableErc721(address token) external view returns (bool); 


    function tokenToLiquidityPool(address token) external view returns (address); 

    // ONLY MANAGER_ROLE FUNCTIONS //

    /**
     * @dev Sets the modular swap router.
     * @param newModularSwapRouter The address of the new modular swap router.
     */
    function setModularSwapRouter(IModularSwapRouter newModularSwapRouter) external;

    /**
     * @dev Sets the liquidity pool address for a given token.
     * @param token The address of the token.
     * @param liquidityPoolAddress The address of the liquidity pool.
     */    
    function setTokenToLiquidityPool(address token, address liquidityPoolAddress) external;

    /**
     * @dev Sets the available tokens for the liquidity pool.
     * @param _availableTokenToLiquidityPool An array of available token addresses.
     */    
    function setAvailableTokenToLiquidityPool(address[] memory _availableTokenToLiquidityPool) external;

    /**
     * @dev Sets the available ERC20 tokens.
     * @param _availableErc20 An array of available ERC20 token addresses.
     */    
    function setAvailableErc20(address[] memory _availableErc20) external;

    /**
     * @dev Sets the availability status of a specific ERC20 token.
     * @param token The address of the ERC20 token.
     * @param value The availability status (true or false).
     */    
    function setIsAvailableErc20(address token, bool value) external;

    /**
     * @dev Sets the available ERC721 tokens.
     * @param _availableErc721 An array of available ERC721 token addresses.
     */    
    function setAvailableErc721(address[] memory _availableErc721) external;
    /**
     * @dev Sets the availability status of a specific ERC721 token.
     * @param token The address of the ERC721 token.
     * @param value The availability status (true or false).
     */    
    function setIsAvailableErc721(address token, bool value) external;

    /**
     * @dev Approves a specific amount of ERC20 tokens for a given address.
     * @param token The address of the ERC20 token.
     * @param to The address to approve.
     * @param amount The amount to approve.
     */
    function approveERC20(address token, address to, uint amount) external;

    // ONLY MARGIN_TRADING_ROLE FUNCTIONS //

    /**
     * @dev Provides ERC20 tokens to a margin account.
     * @param marginAccountID The ID of the margin account.
     * @param txSender The address of the transaction sender.
     * @param token The address of the ERC20 token.
     * @param amount The amount of tokens to provide.
     */
    function provideERC20(uint marginAccountID, address txSender, address token, uint amount) external;

    /**
     * @dev Provides an ERC721 token to a margin account.
     * @param marginAccountID The ID of the margin account.
     * @param txSender The address of the transaction sender.
     * @param token The address of the ERC721 token.
     * @param collateralTokenID The ID of the collateral token.
     */    
    function provideERC721(uint marginAccountID, address txSender, address baseToken, address token, uint collateralTokenID) external;

    /**
     * @dev Withdraws ERC20 tokens from a margin account.
     * @param marginAccountID The ID of the margin account.
     * @param token The address of the ERC20 token.
     * @param amount The amount of tokens to withdraw.
     * @param txSender The address of the transaction sender.
     */    
    function withdrawERC20(uint marginAccountID, address token, uint amount, address txSender) external;

    /**
     * @dev Withdraws an ERC721 token from a margin account.
     * @param marginAccountID The ID of the margin account.
     * @param token The address of the ERC721 token.
     * @param value The ID of the token to withdraw.
     * @param txSender The address of the transaction sender.
     */    
    function withdrawERC721(uint marginAccountID, address token, uint value, address txSender) external;

    /**
     * @dev Borrows ERC20 tokens from a liquidity pool.
     * @param marginAccountID The ID of the margin account.
     * @param token The address of the ERC20 token.
     * @param amount The amount of tokens to borrow.
     */    
    function borrow(uint marginAccountID, address token, uint amount) external;

    /**
     * @dev Repays borrowed ERC20 tokens to a liquidity pool.
     * @param marginAccountID The ID of the margin account.
     * @param token The address of the ERC20 token.
     * @param amount The amount of tokens to repay.
     */    
    function repay(uint marginAccountID, address token, uint amount) external;

    /**
     * @dev Liquidates the assets in a margin account. 
     * @param marginAccountID The ID of the margin account to be liquidated.
     * @param baseToken The address of the base ERC20 token used for liquidation.
     * @param marginAccountOwner The address of the owner of the margin account.
     */
    function liquidate(uint marginAccountID, address baseToken, address marginAccountOwner, address liquidator) external;

    /**
     * @dev Swaps tokens using the modular swap router.
     * @param marginAccountID The ID of the margin account.
     * @param swapID The ID of the swap.
     * @param tokenIn The address of the input token.
     * @param tokenOut The address of the output token.
     * @param amountIn The amount of input tokens.
     * @param amountOutMinimum The minimum amount of output tokens expected.
     */    
    function swap(uint marginAccountID, uint swapID, address tokenIn, address tokenOut, uint amountIn, uint amountOutMinimum) external;

    /**
     * @notice This function allows exercising a position for a given ERC721 token, converting it into the base token.
     * @param marginAccountID The ID of the margin account.
     * @param erc721Token The address of the ERC721 token to be exercised.
     * @param baseToken The address of the base token to be received.
     * @param id The ID of the ERC721 token to be exercised.
     * @param sender The address to which the ERC721 token will be transferred after exercise.
     */
    function exercise(uint marginAccountID, address erc721Token, address baseToken, uint id, address sender) external;

    // EVENTS //

    /**
     * @dev Emitted when the modular swap router is updated.
     * @param newModularSwapRouter The address of the new modular swap router.
     */
    event UpdateModularSwapRouter(
        address newModularSwapRouter
    );

    /**
     * @dev Emitted when the token to liquidity pool mapping is updated.
     * @param token The address of the token.
     * @param liquidityPoolAddress The address of the liquidity pool.
     */
    event UpdateTokenToLiquidityPool(
        address token, 
        address liquidityPoolAddress
    );

    /**
     * @dev Emitted when the available tokens for the liquidity pool are updated.
     * @param availableTokenToLiquidityPool An array of available token addresses.
     */
    event UpdateAvailableTokenToLiquidityPool(
        address[] availableTokenToLiquidityPool
    );

    /**
     * @dev Emitted when the available ERC20 tokens are updated.
     * @param availableErc20 An array of available ERC20 token addresses.
     */
    event UpdateAvailableErc20(
        address[] availableErc20
    );

    /**
     * @dev Emitted when the availability status of an ERC20 token is updated.
     * @param token The address of the ERC20 token.
     * @param value The availability status (true or false).
     */
    event UpdateIsAvailableErc20(
        address token, 
        bool value
    );

    /**
     * @dev Emitted when the available ERC721 tokens are updated.
     * @param availableErc721 An array of available ERC721 token addresses.
     */
    event UpdateAvailableErc721(
        address[] availableErc721
    );

    /**
     * @dev Emitted when the availability status of an ERC721 token is updated.
     * @param token The address of the ERC721 token.
     * @param value The availability status (true or false).
     */
    event UpdateIsAvailableErc721(
        address token, 
        bool value
    );

    event UpdateErc721Limit(
        uint newErc721Limit
    );

    event UpdateLiquidatorFee(
        uint newLiquidatorFee
    );

   /**
     * @dev Emitted when a swap operation is performed.
     * @param swapID The ID of the swap operation.
     * @param tokenIn The address of the input token.
     * @param tokenOut The address of the output token.
     * @param marginAccountID The ID of the margin account.
     * @param amountIn The amount of input tokens swapped.
     * @param amountOut The amount of output tokens received.
     */
    event Swap(
        uint indexed swapID,
        address indexed tokenIn,
        address indexed tokenOut,
        uint marginAccountID,
        uint amountIn,
        uint amountOut
    );

    event Exercise(
        uint indexed marginAccountID,
        uint tokenId,
        address tokenIn,
        address tokenOut,
        uint amountIn
    );

    event LiquidateERC20(
        uint indexed marginAccountID,
        address indexed tokenIn,
        address indexed tokenOut,
        uint amountIn,
        uint amountOut
    );

    event Unlock(
        uint timelock
    );

    event LiquidatorCommission(
        uint amount
    );

    event Lock();
}
