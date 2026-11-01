//SPDX-License-Identifier: UNLICENSED

pragma solidity ^0.8.19;

import "hardhat/console.sol";
import "./interfaces/IERC20.sol";
import "./math/SafeMath.sol";
import "./math/SafeERC20.sol";
import {AggregatorV3Interface} from "./interfaces/ChainLinkAggregatorV3Interface.sol";
import {IAITradeHubContract} from "./interfaces/IAITradeHubContract.sol";

contract SwapContract {
    using SafeMath for uint256;
    using SafeERC20 for IERC20;

    uint constant public DECIMAL_PRECISION = 1e18;
    // Use to convert a price answer to an 18-digit precision uint
    uint constant public TARGET_RATE_DIGITS = 8;

    struct ContractConfig {
        address owner;
        address fundAccount;
        IERC20 mainToken;
        IERC20 usdToken;
        mapping(address => address) tokenWithChainLinkAddress; // Token address => Chainlink oracle address
        address[] supportTokens;
        mapping(address => bool) whiteList;
        uint256 exchangeUSDTRate; // 10**TARGET_RATE_DIGITS mean 10 trai = 1 USDT
        uint256 swapFee; //3 = 0.3%
        IAITradeHubContract aiTradeHubContract;
    }

    struct ChainlinkResponse {
        uint80 roundId;
        int256 answer;
        uint256 timestamp;
        bool success;
        uint8 decimals;
    }

    //Event
    event SwapEvent(address indexed token1, address indexed  token2, uint256 amount, uint256 amountSwap, uint256 rate);

    //Error
    error SwapNotContainMainTokenError();
    error SwapNotContainListedTokenError();
    error SwapAmountInvalidError();
    error SwapInsufficientFundsError();
    error SwapTokenInvalidError();
    error SwapTokenAddressNotInWhiteListError();
    error SwapTokenGetPriceError();

    ContractConfig public config;

    modifier onlyOwner() {
        require(msg.sender == config.owner, "Not the owner");
        _;
    }

    constructor(address fundAccount, address mainToken, address usdToken, address[] memory exchangeTokenAddress, address[] memory exchangeTokenChainLinkAddress, uint256 rate, uint256 swapFee, address aiTradeHubContractAddress){
        config.owner = msg.sender;
        config.fundAccount = fundAccount;
        config.mainToken = IERC20(mainToken);
        config.usdToken = IERC20(usdToken);
        config.exchangeUSDTRate = rate;
        config.swapFee = swapFee;
        config.aiTradeHubContract = IAITradeHubContract(aiTradeHubContractAddress);
        for (uint i = 0; i < exchangeTokenAddress.length; i++) {
            config.tokenWithChainLinkAddress[exchangeTokenAddress[i]] = exchangeTokenChainLinkAddress[i];
            config.supportTokens.push(exchangeTokenAddress[i]);
        }
    }

    //PUBLIC function
    function swap(address fromToken, address toToken, uint256 amount) external {
        if(amount == 0) revert SwapAmountInvalidError();
        address mainTokenAddress = address(config.mainToken);
        if (fromToken != mainTokenAddress && toToken != mainTokenAddress)
            revert SwapNotContainMainTokenError();
        if (!_isInWhiteList(msg.sender))
            revert SwapTokenAddressNotInWhiteListError();

        uint256 swapRate = _getSwapRate(fromToken, toToken);
        _swap(IERC20(fromToken), IERC20(toToken), amount, swapRate);
    }

    function estimateSwapAmount(address fromToken, address toToken, uint256 amount) public view returns (uint256){
        uint256 swapRate = _getSwapRate(fromToken, toToken);
        uint256 swapAmount = _getSwapAmount(amount, swapRate);
        return swapAmount;
    }

    function supportTokens() public view returns (address[] memory){
        return config.supportTokens;
    }

    function getUSDPrice(address tokenAddress) public view returns (uint256){
        if (tokenAddress == address(0))
            revert SwapTokenInvalidError();
        if (tokenAddress == address(config.mainToken))
            return (10 ** (TARGET_RATE_DIGITS * 2)).div(config.exchangeUSDTRate);

        if (tokenAddress == address(config.usdToken))
            return 10 ** TARGET_RATE_DIGITS;

        address chainLinkAddress = config.tokenWithChainLinkAddress[tokenAddress];
        if (chainLinkAddress == address(0))
            revert SwapTokenInvalidError();
        return _fetchPrice(chainLinkAddress);
    }

    function getSwapRate(address fromToken, address toToken) public view returns (uint256){
        return _getSwapRate(fromToken, toToken);
    }

    function isInWhiteList(address _address) public view returns (bool){
        return _isInWhiteList(_address);
    }

    //PUBLIC function END

    //OWNER function
    function addExchangeToken(address tokenAddress, address chainLinkTokenAddress) onlyOwner public {
        if (tokenAddress == address(0) || chainLinkTokenAddress == address(0)) {
            revert SwapTokenInvalidError();
        }
        config.tokenWithChainLinkAddress[tokenAddress] = chainLinkTokenAddress;
        config.supportTokens.push(tokenAddress);
    }

    function removeExchangeToken(address tokenAddress) onlyOwner public {
        if (tokenAddress == address(0)) {
            revert SwapTokenInvalidError();
        }
        delete config.tokenWithChainLinkAddress[tokenAddress];
        for (uint i = 0; i < config.supportTokens.length; i++) {
            if (config.supportTokens[i] == tokenAddress) {
                delete config.supportTokens[i];
            }
        }
    }

    function addAddressToWhiteList(address verifiedAddress) onlyOwner public {
        if(config.whiteList[verifiedAddress]) return;
        config.whiteList[verifiedAddress] = true;
    }

    function removeAddressInWhiteList(address walletAddress) onlyOwner public {
        if(!config.whiteList[walletAddress]) return;
        (,
            ,
            ,
            ,
            uint256 user_locked_amount,
            uint256 user_pending_amount,
            ,
            uint256 user_balance,
            uint256 user_claimable_profit,
            ,
            ) = config.aiTradeHubContract.getStats(walletAddress);
        //If user have funds then not remove it
        if(user_locked_amount > 0 || user_pending_amount > 0 || user_balance > 0 || user_claimable_profit > 0)
            return;
        config.whiteList[walletAddress] = false;
    }

    function setExchangeUSDTRate(uint256 rate) onlyOwner public {
        if (rate > 0)
            config.exchangeUSDTRate = rate;
    }

    function setSwapFee(uint256 fee) onlyOwner public {
        if (fee > 0)
            config.swapFee = fee;
    }

    function setUSDToken(address usdTokenAddress) onlyOwner public {
        if (usdTokenAddress != address(0))
            config.usdToken = IERC20(usdTokenAddress);
    }
    function setAITradeHubContractAddress(address aiTradeHubContractAddress) onlyOwner public{
        config.aiTradeHubContract = IAITradeHubContract(aiTradeHubContractAddress);
    }
    //OWNER function END
    function _swap(IERC20 fromToken, IERC20 toToken, uint256 amount, uint256 rate) internal {
        uint256 senderTokenBalance = fromToken.balanceOf(msg.sender);
        if (senderTokenBalance <= 0) revert SwapInsufficientFundsError();
        fromToken.safeTransferFrom(msg.sender, config.fundAccount, amount);
        uint256 swapAmount = _getSwapAmount(amount, rate);
        toToken.safeTransferFrom(config.fundAccount, msg.sender, swapAmount);
        console.log("Swap: amount %s rate %s, Swap amount %s", amount, rate, swapAmount);
        emit SwapEvent(address(fromToken), address(toToken), amount, swapAmount, rate);
    }

    function _getSwapAmount(uint256 amount, uint256 rate) internal view returns (uint256){
        uint256 swapAmount = amount.mul(rate).div(10 ** TARGET_RATE_DIGITS);
        uint256 swapFeeAmount = swapAmount.mul(config.swapFee).div(1000);
        swapAmount = swapAmount.sub(swapFeeAmount);
        return swapAmount;
    }

    function _getSwapRate(address fromToken, address toToken) internal view returns (uint256){
        address mainTokenAddress = address(config.mainToken);
        uint256 rate;
        // USDT -> TRAI
        if (fromToken == address(config.usdToken)) {
            rate = config.exchangeUSDTRate;
        }
            // TRAI -> USDT
        else if (toToken == address(config.usdToken)) {
            rate = (10 ** (TARGET_RATE_DIGITS * 2)).div(config.exchangeUSDTRate);
        }
        else {
            address otherTokenAddress;
            if (fromToken == mainTokenAddress) {
                otherTokenAddress = toToken;
            } else {
                otherTokenAddress = fromToken;
            }
            address chainLinkTokenAddress = config.tokenWithChainLinkAddress[otherTokenAddress];
            if (chainLinkTokenAddress == address(0)) revert SwapNotContainListedTokenError();
            uint256 tokenPrice = _fetchPrice(chainLinkTokenAddress);
            if (tokenPrice <= 0)
                revert SwapTokenGetPriceError();
            // TRAI -> OTHER
            if (fromToken == mainTokenAddress) {
                rate = (10 ** (TARGET_RATE_DIGITS * 2)).div(config.exchangeUSDTRate).mul(10 ** TARGET_RATE_DIGITS).div(tokenPrice);
            }
                //OTHER -> TRAI
            else {
                rate = (tokenPrice * config.exchangeUSDTRate).div(10 ** TARGET_RATE_DIGITS);
            }
        }
        return rate;
    }

    function _fetchPrice(address chainLinkTokenAddress) internal view returns (uint) {
        ChainlinkResponse memory _chainlinkResponse = _getCurrentChainlinkResponse(AggregatorV3Interface(chainLinkTokenAddress));
        uint scaledChainlinkPrice = _scaleChainlinkPriceByDigits(uint256(_chainlinkResponse.answer), _chainlinkResponse.decimals);
        return scaledChainlinkPrice;
    }

    function _getCurrentChainlinkResponse(AggregatorV3Interface priceAggregator) internal view returns (ChainlinkResponse memory chainlinkResponse) {
        // First, try to get current decimal precision:
        try priceAggregator.decimals() returns (uint8 decimals) {
            // If call to Chainlink succeeds, record the current decimal precision
            chainlinkResponse.decimals = decimals;
        } catch {
            // If call to Chainlink aggregator reverts, return a zero response with success = false
            return chainlinkResponse;
        }

        // Secondly, try to get latest price data:
        try priceAggregator.latestRoundData() returns
        (
            uint80 roundId,
            int256 answer,
            uint256 /* startedAt */,
            uint256 timestamp,
            uint80 /* answeredInRound */
        )
        {
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

    function _scaleChainlinkPriceByDigits(uint _price, uint _answerDigits) internal pure returns (uint) {
        uint price;
        if (_answerDigits >= TARGET_RATE_DIGITS) {
            // Scale the returned price value down to ourProject's target precision
            price = _price / (10 ** (_answerDigits - TARGET_RATE_DIGITS));
        }
        else if (_answerDigits < TARGET_RATE_DIGITS) {
            // Scale the returned price value up to ourProject's target precision
            price = _price * (10 ** (TARGET_RATE_DIGITS - _answerDigits));
        }
        return price;
//        return 20 * 10 ** TARGET_RATE_DIGITS;
    }

    function _isInWhiteList(address _address) internal view returns (bool){
        return config.whiteList[_address];
    }
}