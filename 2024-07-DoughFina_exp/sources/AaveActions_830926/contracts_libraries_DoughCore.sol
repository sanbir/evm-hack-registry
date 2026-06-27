// SPDX-License-Identifier: BUSL-1.1
pragma solidity =0.8.24;

import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@aave/core-v3/contracts/interfaces/IPoolDataProvider.sol";
import "@aave/core-v3/contracts/interfaces/IPool.sol";
import "@uniswap/v3-periphery/contracts/interfaces/IQuoter.sol";
import "@uniswap/v3-periphery/contracts/interfaces/ISwapRouter.sol";
import { IWETH, IDoughIndex, CustomError } from "../Interfaces.sol";

/**
* $$$$$$$\                                $$\             $$$$$$$$\ $$\                                                   
* $$  __$$\                               $$ |            $$  _____|\__|                                                  
* $$ |  $$ | $$$$$$\  $$\   $$\  $$$$$$\  $$$$$$$\        $$ |      $$\ $$$$$$$\   $$$$$$\  $$$$$$$\   $$$$$$$\  $$$$$$\  
* $$ |  $$ |$$  __$$\ $$ |  $$ |$$  __$$\ $$  __$$\       $$$$$\    $$ |$$  __$$\  \____$$\ $$  __$$\ $$  _____|$$  __$$\ 
* $$ |  $$ |$$ /  $$ |$$ |  $$ |$$ /  $$ |$$ |  $$ |      $$  __|   $$ |$$ |  $$ | $$$$$$$ |$$ |  $$ |$$ /      $$$$$$$$ |
* $$ |  $$ |$$ |  $$ |$$ |  $$ |$$ |  $$ |$$ |  $$ |      $$ |      $$ |$$ |  $$ |$$  __$$ |$$ |  $$ |$$ |      $$   ____|
* $$$$$$$  |\$$$$$$  |\$$$$$$  |\$$$$$$$ |$$ |  $$ |      $$ |      $$ |$$ |  $$ |\$$$$$$$ |$$ |  $$ |\$$$$$$$\ \$$$$$$$\ 
* \_______/  \______/  \______/  \____$$ |\__|  \__|      \__|      \__|\__|  \__| \_______|\__|  \__| \_______| \_______|
*                               $$\   $$ |                                                                                
*                               \$$$$$$  |                                                                                
*                                \______/                                                                                 
* 
* @title DoughCore
* @notice The core contract for Dough Finance
* @custom:version 1.0 - Initial release
* @author Liberalite https://github.com/liberalite
* @custom:coauthor 0xboga https://github.com/0xboga
*/
library DoughCore {
    using SafeERC20 for IERC20;

    // MAINNET
    uint256 public constant CHAIN_ID = 1;

    // TOKENS
    address public constant ADDRESS_ZERO = 0x0000000000000000000000000000000000000000;
    address public constant ETH = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;
    address public constant WBTC = 0x2260FAC5E5542a773Aa44fBCfeDf7C193bc2C599;
    address public constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address public constant LINK = 0x514910771AF9Ca656af840dff83E8264EcF986CA;
    address public constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address public constant USDT = 0xdAC17F958D2ee523a2206206994597C13D831ec7;
    address public constant DAI = 0x6B175474E89094C44Da98b954EedeAC495271d0F;

    // AAVE V3 CONFIG
    uint256 public constant FLASHLOAN_RATE_MODE = 0; // no borrow debt
    uint256 public constant VARIABLE_RATE_MODE = 2; // variable borrow rate 

    // AAVE V3 ADDRESSES
    address public constant AAVE_V3_POOL_ADDRESS = 0x87870Bca3F3fD6335C3F4ce8392D69350B4fA4E2;
    address public constant AAVE_V3_DATA_PROVIDER_ADDRESS = 0x7B4EB56E7CD4b454BA8ff71E4518426369a138a3;
    address public constant AAVE_V3_POOL_ADDRESS_PROVIDER = 0x2f39d218133AFaB8F2B819B1066c7E434Ad94E9e;

    // UNISWAP V2
    address public constant UNISWAP_V2_ROUTER_ADDRESS = 0x7a250d5630B4cF539739dF2C5dAcb4c659F2488D;

    // UNISWAP V3
    address public constant UNISWAP_V3_ROUTER_ADDRESS = 0xE592427A0AEce92De3Edee1F18E0157C05861564;
    address public constant UNISWAP_V3_QUOTER_ADDRESS = 0xb27308f9F90D607463bb33eA1BeBb41C27CE5AB6;

    // UNISWAP V3 INTERFACES
    ISwapRouter public constant _I_UNISWAP_V3_ROUTER = ISwapRouter(UNISWAP_V3_ROUTER_ADDRESS);
    IQuoter public constant _I_UNISWAP_V3_QUOTER = IQuoter(UNISWAP_V3_QUOTER_ADDRESS);

    // AAVE V3 INTERFACES
    IPool public constant _I_AAVE_V3_POOL = IPool(AAVE_V3_POOL_ADDRESS);
    IPoolDataProvider public constant _I_AAVE_V3_DATA_PROVIDER = IPoolDataProvider(AAVE_V3_DATA_PROVIDER_ADDRESS);

    // DOUGH CONNECTORS ID
    uint256 public constant CONNECTOR_ID0 = 0;
    uint256 public constant CONNECTOR_ID1 = 1;
    uint256 public constant CONNECTOR_ID2 = 2;
    uint256 public constant CONNECTOR_ID3 = 3;
    uint256 public constant CONNECTOR_ID4 = 4;
    uint256 public constant CONNECTOR_ID5 = 5;
    uint256 public constant CONNECTOR_ID6 = 6;
    uint256 public constant CONNECTOR_ID7 = 7;
    uint256 public constant CONNECTOR_ID8 = 8;
    uint256 public constant CONNECTOR_ID9 = 9;
    uint256 public constant CONNECTOR_ID10 = 10;
    uint256 public constant CONNECTOR_ID11 = 11;
    uint256 public constant CONNECTOR_ID12 = 12;
    uint256 public constant CONNECTOR_ID13 = 13;
    uint256 public constant CONNECTOR_ID14 = 14;
    uint256 public constant CONNECTOR_ID15 = 15;
    uint256 public constant CONNECTOR_ID16 = 16;
    uint256 public constant CONNECTOR_ID17 = 17;
    uint256 public constant CONNECTOR_ID18 = 18;
    uint256 public constant CONNECTOR_ID19 = 19;
    uint256 public constant CONNECTOR_ID20 = 20;
    uint256 public constant CONNECTOR_ID21 = 21;
    uint256 public constant CONNECTOR_ID22 = 22;
    uint256 public constant CONNECTOR_ID23 = 23;
    uint256 public constant CONNECTOR_ID24 = 24;
    uint256 public constant CONNECTOR_ID25 = 25;
    uint256 public constant CONNECTOR_ID26 = 26;
    uint256 public constant CONNECTOR_ID27 = 27;
    uint256 public constant CONNECTOR_ID28 = 28;
    uint256 public constant CONNECTOR_ID29 = 29;
    uint256 public constant CONNECTOR_ID30 = 30;
    uint256 public constant CONNECTOR_ID31 = 31;
    uint256 public constant CONNECTOR_ID32 = 32;
    uint256 public constant CONNECTOR_ID33 = 33;

    /**
     * @notice Function to repay AAVE V3 debt with Aave Tokens
     * @param _tokenIn The token address to repay the debt
     * @param _inAmount The amount of the token to repay the debt
     * @dev The token should be whitelisted in the DoughIndex contract
     */
    function repayWithATokens(address _tokenIn, uint256 _inAmount) external {
        _I_AAVE_V3_POOL.repayWithATokens(_tokenIn, _inAmount, VARIABLE_RATE_MODE);
    }

    /**
    * @notice Collects the APY fees for all the whitelisted tokens
    * @param _doughIndex The DoughIndex address
    * @dev The APY fees are collected for all the whitelisted tokens
    */
    function collectApyFees(address _doughIndex) external {
        // Check if the flash borrower is the caller
        if(IDoughIndex(_doughIndex).getFlashBorrowers(address(this))) return;

        // Get the whitelisted tokens
        address[] memory whitelistedTokens = IDoughIndex(_doughIndex).getWhitelistedTokenList();

        // Iterate through the whitelisted tokens
        for (uint i = 0; i < whitelistedTokens.length;) {
            // Get the APY fees for the given token
            (, , uint256 scaledInterest, uint256 minInterest) = IDoughIndex(_doughIndex).borrowFormula(whitelistedTokens[i], address(this));

            // Check if the scaled interest is greater than the minimum interest
            if (scaledInterest > minInterest) collectTreasuryFees(_doughIndex, address(this), whitelistedTokens[i], scaledInterest);

            // Increment the counter
            unchecked { i++; }
        }
    }

    /**
    * @notice Collects the APY fees for the given token if minimum interest is met
    * @param _doughIndex The DoughIndex address
    * @param _token: The whitelisted token address
    */
    function collectAnyApyFees(address _doughIndex, address _token) external {
        // Check if the flash borrower is the caller
        if(IDoughIndex(_doughIndex).getFlashBorrowers(address(this))) return;
        
        // Get the APY fees for the given token
        (, , uint256 scaledInterest, uint256 minInterest) = IDoughIndex(_doughIndex).borrowFormula(_token, address(this));
        
        // Check if the scaled interest is greater than the minimum interest
        if (scaledInterest > minInterest) collectTreasuryFees(_doughIndex, address(this), _token, scaledInterest);
    }

    /**
    * @notice Collects the APY fees for the given token 
    * @param _doughIndex The DoughIndex address
    * @param _token: The whitelisted token address
    */
    function collectApyFeesInterest(address _doughIndex, address _token) external {
        // Check if the flash borrower is the caller
        if(IDoughIndex(_doughIndex).getFlashBorrowers(address(this))) return;
        
        // Get the time when the borrowing started
        (uint256 scaledInterest) = IDoughIndex(_doughIndex).borrowFormulaInterest(_token, address(this));

        // Check if the scaled interest is greater than 0
        if (scaledInterest > 0) collectTreasuryFees(_doughIndex, address(this), _token, scaledInterest);
    }

    /**
    * @notice Collects the APY fees for the given token partially
    * @param _doughIndex The DoughIndex address
    * @param _token: The whitelisted token address
    * @param _partialAmount The partial amount of APY fees
    */
    function collectApyFeesPartially(address _doughIndex, address _token, uint256 _partialAmount) private {
        // Check if the flash borrower is the caller
        if(IDoughIndex(_doughIndex).getFlashBorrowers(address(this))) return;

        // Get the time when the borrowing started
        uint256 timeStartedBorrow = IDoughIndex(_doughIndex).getDsaBorrowStartDate(address(this), _token);

        // Get the scaled interest for the given token
        (uint256 scaledInterest) = IDoughIndex(_doughIndex).borrowFormulaInterest(_token, address(this));

        // Check if the partial amount is greater than the scaled interest
        if (_partialAmount > scaledInterest) revert CustomError("partialAmount >= scaled interest");

        // Calculate the time difference between the current time and the time when the borrowing started
        uint256 timeDiff = block.timestamp - timeStartedBorrow;

        // Calculate the APY fees per second
        uint256 perSecond = scaledInterest / timeDiff;

        // Check if the perSecond is 0
        if (perSecond == 0) revert CustomError("perSecond is 0");

        // Calculate the back time in seconds
        uint256 backTimeInSeconds = (_partialAmount * 1e18) / perSecond;

        // Check if the backTimeInSeconds is 0
        uint256 actualBackTimeInSeconds = backTimeInSeconds / 1e18;

        // Check if the actualBackTimeInSeconds is 0
        if (actualBackTimeInSeconds == 0) revert CustomError("actualBackTimeInSeconds is 0");

        // Calculate the adjusted start time after partial APY fees collection
        uint256 adjustedStartTime = timeStartedBorrow + actualBackTimeInSeconds;

        // Collect the APY fees partially
        collectTreasuryFeesPartially(_doughIndex, _token, address(this), scaledInterest, _partialAmount, adjustedStartTime);
    }

    /**
    * @notice Collects the APY fees for the given token
    * @param _doughIndex The DoughIndex address
    * @param _dsaAddress The DSA address
    * @param _token: The whitelisted token address
    * @param _scaledInterest The scaled interest of APY fees
    */
    function collectTreasuryFees(address _doughIndex, address _dsaAddress, address _token, uint256 _scaledInterest) private {
        // Borrow the APY fees from the Aave V3 pool
        _I_AAVE_V3_POOL.borrow(_token, _scaledInterest, VARIABLE_RATE_MODE, 0, address(this));

        // Transfer the fee to the treasury
        IERC20(_token).safeTransfer(IDoughIndex(_doughIndex).treasury(), _scaledInterest);
        
        // Update the borrow start date to now, as a new fee period starts
        IDoughIndex(_doughIndex).updateBorrowDate(CONNECTOR_ID0, block.timestamp, _dsaAddress, _token);
    }

    /**
    * @notice Collects the APY fees for the given token partially
    * @param _token: The token address to collect the APY fees
    * @param _dsaAddress: The DSA address to collect the APY fees
    * @param _scaledInterest: The scaled interest to collect the APY fees
    * @param _partialAmount: The partial amount to collect the APY fees
    * @param _adjustedStartTime: The adjusted start time after partial APY fees collection
    */
    function collectTreasuryFeesPartially(address _doughIndex, address _token, address _dsaAddress, uint256 _scaledInterest, uint256 _partialAmount, uint256 _adjustedStartTime) private {
        // Check if the scaled interest is greater than the partial amount
        if (_scaledInterest >= _partialAmount) {
            // Borrow the APY fees from the Aave V3 pool
            _I_AAVE_V3_POOL.borrow(_token, _partialAmount, VARIABLE_RATE_MODE, 0, address(this));
            
            // Transfer the fee to the treasury
            IERC20(_token).safeTransfer(IDoughIndex(_doughIndex).treasury(), _partialAmount);
            
            // Update the borrow start date to now, as a new fee period starts
            IDoughIndex(_doughIndex).updateBorrowDate(CONNECTOR_ID0, _adjustedStartTime, _dsaAddress, _token);
        }
    }
}