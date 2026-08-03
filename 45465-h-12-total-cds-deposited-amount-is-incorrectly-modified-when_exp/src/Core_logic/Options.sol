// SPDX-License-Identifier: MIT

pragma solidity 0.8.22;

import "../interface/ITreasury.sol";
import "../interface/CDSInterface.sol";
import "../interface/IBorrowing.sol";
import "../interface/IGlobalVariables.sol";
import "../interface/IOptions.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

/**
 * @title Options contract
 * @author Autonomint
 * @notice Main contract for options fees calculation
 * - Users can View options fees for their depositing collateral
 * - This contract calculates the strike price profit or loss for the borrower.
 */
contract Options is IOptions,Initializable, UUPSUpgradeable, OwnableUpgradeable {
    uint256 private PRECISION;
    uint256 private ETH_PRICE_PRECISION;
    uint256 private OPTION_PRICE_PRECISION;
    uint128 private USDA_PRECISION;

    ITreasury treasury; // Treasury instance
    CDSInterface cds; // CDS instance
    IBorrowing borrowing; // Borrowing instance
    IGlobalVariables private globalVariables; // Global variables instance

    /**
     * @dev Initialize function to initialize the contract
     * @param _treasuryAddress Treasury contract address
     * @param _cdsAddress CDS contract address
     * @param _borrowingAddress Borrowing contract address
     * @param _globalVariables Global Variables Address
     */
    function initialize(
        address _treasuryAddress,
        address _cdsAddress,
        address _borrowingAddress,
        address _globalVariables
    ) public initializer {
        // Initialize Owner of the contract
        __Ownable_init(msg.sender);
        // INitialize Proxy
        __UUPSUpgradeable_init();
        treasury = ITreasury(_treasuryAddress);
        cds = CDSInterface(_cdsAddress);
        borrowing = IBorrowing(_borrowingAddress);
        globalVariables = IGlobalVariables(_globalVariables);
        PRECISION = 1e18;
        ETH_PRICE_PRECISION = 1e6;
        OPTION_PRICE_PRECISION = 1e5;
        USDA_PRECISION = 1e12;
    }

    function _authorizeUpgrade(
        address newImplementation
    ) internal override onlyOwner {}

    /**
     * @dev Modofier which will check whether the caller is borrowing contract or not
     */
    modifier onlyBorrowingContract() {
        require(msg.sender == address(borrowing),"This function can only called by borrowing contract");
        _;
    }

    /**
     * @dev calculate eth price gains for the user
     * @param depositedAmount eth amount to be deposit
     * @param strikePrice strikePrice,not percent, price
     * @param ethPrice eth price
     */
    function calculateStrikePriceGains(
        uint128 depositedAmount,
        uint128 strikePrice,
        uint64 ethPrice
    ) external view onlyBorrowingContract returns (uint128) {
        // Check the input params are non zero
        require(depositedAmount != 0 && strikePrice != 0 && ethPrice != 0,"Zero inputs in options");
        uint64 currentEthPrice = ethPrice;
        // Calculate current deposited ETH value in USD
        uint128 currentEthValue = depositedAmount * currentEthPrice;
        uint128 ethToReturn;
        // If the current value is greater, then user will get eth
        if (currentEthValue > strikePrice) {
            ethToReturn = (currentEthValue - strikePrice) / currentEthPrice;
        } else {
            ethToReturn = 0;
        }
        return ethToReturn;
    }

    /**
     * @dev Function to calculate option fees
     * @param _ethPrice ETH price
     * @param _ethVolatility ETH volatility for 30days
     * @param _amount Depositing amount
     * @param _strikePrice Strike price chosen by user
     */
    function calculateOptionPrice(
        uint128 _ethPrice,
        uint256 _ethVolatility,
        uint256 _amount,
        StrikePrice _strikePrice
    ) public view returns (uint256) {
        uint256 a = _ethVolatility;
        uint256 ethPrice = _ethPrice; /*getLatestPrice();*/
        // Get global omnichain data
        IGlobalVariables.OmniChainData memory omniChainData = globalVariables.getOmniChainData();
        // Calculate the current ETH vault value
        uint256 E = omniChainData.totalVolumeOfBorrowersAmountinUSD + (_amount * _ethPrice);
        // Check the ETH vault is not zero
        require(E != 0, "No borrowers in protocol");
        uint256 cdsVault;
        // If the there is no borrowers in borrowing, then the cdsVault value is deposited value itself
        if (omniChainData.noOfBorrowers == 0) {
            cdsVault = omniChainData.totalCdsDepositedAmount * USDA_PRECISION;
        } else {
            // Else, get the cds vault current value from omnichain global data
            cdsVault = omniChainData.cdsPoolValue * USDA_PRECISION;
        }

        // Check cds vault is non zero
        require(cdsVault != 0, "CDS Vault is zero");
        // Calculate b, cdsvault to eth vault ratio
        uint256 b = (cdsVault * 1e2 * OPTION_PRICE_PRECISION) / E;
        uint256 baseOptionPrice = ((sqrt(10 * a * ethPrice)) * PRECISION) / OPTION_PRICE_PRECISION + ((3 * PRECISION * OPTION_PRICE_PRECISION) / b); // 1e18 is used to handle division precision

        uint256 optionPrice;
        // Calculate option fees based on strike price chose by user
        if (_strikePrice == StrikePrice.FIVE) {
            // constant has extra 1e3 and volatility have 1e8
            optionPrice = baseOptionPrice + (400 * OPTION_PRICE_PRECISION * baseOptionPrice) / (3 * a);
        } else if (_strikePrice == StrikePrice.TEN) {
            optionPrice = baseOptionPrice + (100 * OPTION_PRICE_PRECISION * baseOptionPrice) / (3 * a);
        } else if (_strikePrice == StrikePrice.FIFTEEN) {
            optionPrice = baseOptionPrice + (50 * OPTION_PRICE_PRECISION * baseOptionPrice) / (3 * a);
        } else if (_strikePrice == StrikePrice.TWENTY) {
            optionPrice = baseOptionPrice + (10 * OPTION_PRICE_PRECISION * baseOptionPrice) / (3 * a);
        } else if (_strikePrice == StrikePrice.TWENTY_FIVE) {
            optionPrice = baseOptionPrice + (5 * OPTION_PRICE_PRECISION * baseOptionPrice) / (3 * a);
        } else {
            revert("Incorrect Strike Price");
        }
        return ((optionPrice * _amount) / PRECISION) / USDA_PRECISION;
    }

    // Provided square root function
    function sqrt(uint y) internal pure returns (uint z) {
        if (y > 3) {
            z = y;
            uint x = y / 2 + 1;
            while (x < z) {
                z = x;
                x = (y / x + x) / 2;
            }
        } else if (y != 0) {
            z = 1;
        }
    }
}
