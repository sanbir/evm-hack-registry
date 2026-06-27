// SPDX-License-Identifier: MIT

pragma solidity 0.6.11;

import "./Interfaces/IPriceFeed.sol";
import "./Interfaces/IOracle.sol";
import "./Dependencies/AggregatorV3Interface.sol";
import "./Dependencies/SafeMath.sol";
import "./Dependencies/Ownable.sol";
import "./Dependencies/CheckContract.sol";
import "./Dependencies/BaseMath.sol";
import "./Dependencies/LiquityMath.sol";

interface IUMBOracle {
    function getPrice() external view returns (uint256);
}

/*
 * PriceFeed for mainnet deployment, to be connected to Chainlink's live ETH:USD aggregator reference
 * contract, and a wrapper contract TellorCaller, which connects to TellorMaster contract.
 *
 * The PriceFeed uses Chainlink as primary oracle, and Tellor as fallback. It contains logic for
 * switching oracles based on oracle failures, timeouts, and conditions for returning to the primary
 * Chainlink oracle.
 */
contract PriceFeed is Ownable, CheckContract, BaseMath, IPriceFeed {
    using SafeMath for uint256;

    string public constant NAME = "PriceFeed";

    AggregatorV3Interface public chainlinkOracle;
    IUMBOracle public umbOracle;

    // GMU oracle.
    IOracle public gmuOracle;

    // Use to convert a price answer to an 18-digit precision uint.
    uint256 public constant TARGET_DIGITS = 18;

    struct ChainlinkResponse {
        uint80 roundId;
        int256 answer;
        uint256 timestamp;
        bool success;
        uint8 decimals;
    }

    // --- Dependency setters ---

    function setAddresses(
        address _umbOracle,
        address _chainlinkOracleAddress,
        address _gmuOracle
    ) external onlyOwner {
        checkContract(_gmuOracle);

        umbOracle = IUMBOracle(_umbOracle);
        chainlinkOracle = AggregatorV3Interface(_chainlinkOracleAddress);
        gmuOracle = IOracle(_gmuOracle);

        _renounceOwnership();
    }

    // --- Functions ---

    /*
     * fetchPrice():
     * Returns the latest price obtained from the Oracle. Called by Liquity functions that require a current price.
     *
     * Also callable by anyone externally.
     *
     * Non-view function - it stores the last good price seen by Liquity.
     *
     * Uses a main oracle (Chainlink) and a fallback oracle (Tellor) in case Chainlink fails. If both fail,
     * it uses the last good price seen by Liquity.
     *
     */
    function fetchPrice() external override returns (uint256) {
        // If uniswap pair oracle is not set, that means, the desired collateral
        // has a direct price aggregator, hence we fetch price without uniswap pair oracle.
        // i.e we fetch price from base to usd using chainlink and then usd to gmu using gmu oracle.
        if (address(umbOracle) == address(0)) return fetchPriceWithoutUMB();

        // Else, we fetch price from uniswap base to quote, then from quote to usd using chainlink,
        // and finally usd to gmu using gmu oracle.
        return fetchPriceWithUMB();
    }

    function fetchPriceWithoutUMB() public view returns (uint256) {
        uint256 gmuPrice = _fetchGMUPrice();
        uint256 chainlinkPrice = _fetchChainlinkPrice();
        return (chainlinkPrice.mul(10**TARGET_DIGITS).div(gmuPrice));
    }

    function fetchPriceWithUMB() public view returns (uint256) {
        uint256 gmuPrice = _fetchGMUPrice();
        uint256 umbPrice = _fetchUMBPrice();
        return (umbPrice.mul(10**TARGET_DIGITS).div(gmuPrice));
    }

    function _scalePriceByDigits(uint256 _price, uint256 _answerDigits)
        internal
        pure
        returns (uint256)
    {
        // Convert the price returned by the oracle to an 18-digit decimal for use.
        uint256 price;
        if (_answerDigits >= TARGET_DIGITS) {
            // Scale the returned price value down to Liquity's target precision
            price = _price.div(10**(_answerDigits - TARGET_DIGITS));
        } else if (_answerDigits < TARGET_DIGITS) {
            // Scale the returned price value up to Liquity's target precision
            price = _price.mul(10**(TARGET_DIGITS - _answerDigits));
        }
        return price;
    }

    function _fetchUMBPrice() internal view returns (uint256) {
        return _scalePriceByDigits(umbOracle.getPrice(), 18);
    }

    function _fetchGMUPrice() internal view returns (uint256) {
        uint256 gmuPrice = gmuOracle.getPrice();
        uint256 gmuPricePrecision = gmuOracle.getDecimalPercision();
        return _scalePriceByDigits(gmuPrice, gmuPricePrecision);
    }

    function _fetchChainlinkPrice() internal view returns (uint256) {
        ChainlinkResponse memory chainlinkResponse = _getCurrentChainlinkResponse();
        uint256 scaledChainlinkPrice = _scalePriceByDigits(
            uint256(chainlinkResponse.answer),
            chainlinkResponse.decimals
        );
        return scaledChainlinkPrice;
    }

    // --- Oracle response wrapper functions ---
    function _getCurrentChainlinkResponse()
        internal
        view
        returns (ChainlinkResponse memory chainlinkResponse)
    {
        // First, try to get current decimal precision:
        try chainlinkOracle.decimals() returns (uint8 decimals) {
            // If call to Chainlink succeeds, record the current decimal precision
            chainlinkResponse.decimals = decimals;
        } catch {
            // If call to Chainlink aggregator reverts, return a zero response with success = false
            return chainlinkResponse;
        }

        // Secondly, try to get latest price data:
        try chainlinkOracle.latestRoundData() returns (
            uint80 roundId,
            int256 answer,
            uint256, /* startedAt */
            uint256 timestamp,
            uint80 /* answeredInRound */
        ) {
            // If call to Chainlink succeeds, return the response and success = true
            chainlinkResponse.roundId = roundId;
            chainlinkResponse.answer = answer;
            chainlinkResponse.timestamp = timestamp;
            chainlinkResponse.success = true;
            return chainlinkResponse;
        } catch {
            // If call to Chainlink aggregator reverts, return a zero response with success = false
            return chainlinkResponse;
        }
    }
}
