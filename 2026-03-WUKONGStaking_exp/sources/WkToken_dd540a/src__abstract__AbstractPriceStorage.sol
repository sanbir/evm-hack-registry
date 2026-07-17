// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IPriceStorage} from "../interfaces/IPriceStorage.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IUniswapV2Factory} from "v2-core/interfaces/IUniswapV2Factory.sol";
import {IUniswapV2Pair} from "v2-core/interfaces/IUniswapV2Pair.sol";

/**
 * @title 价格存储
 * @notice 用于记录昨日收盘价、根据昨日收盘价计算当前涨跌幅
 * @dev
 */
abstract contract AbstractPriceStorage is IPriceStorage {
    //价格精度
    uint256 public constant PRICE_DECIMALS = 1e18;
    //日期 => 开盘价
    mapping(uint256 => PriceTime) private _dailyOpenPrices;
    //最近的价格
    PriceTime private _latestPrice;
    address public baseToken;
    address public quoteToken;
    IUniswapV2Pair public pair;
    IUniswapV2Pair public usdtPair;
    address private usdtAddr;

    event AdminSetOpenPrice(uint256 timestamp, uint256 price);

    ///@dev 当参数传0地址时不执行任何初始化，需要后续通过_init函数初始化
    // constructor(address _factoryAddress, address _baseToken, address _quoteToken) {
    //     if(_factoryAddress != address(0) && _baseToken != address(0) && _quoteToken != address(0)) {
    //         baseToken = _baseToken;
    //         quoteToken = _quoteToken;
    //         pair = IUniswapV2Pair(UniswapLibrary.pairFor(_factoryAddress, _baseToken, _quoteToken));
    //         require(address(pair) != address(0), "PriceStorage: INVALID_PAIR");
    //         try pair.totalSupply() returns (uint256 totalSupply) {
    //             if(totalSupply > 0) {
    //                 _syncPrice();
    //             }
    //         } catch {

    //         }
    //     }
    // }

    function _init(address _baseToken, address _quoteToken, address _pair) internal {
        require(baseToken == address(0), "PriceStorage: ALREADY_INIT");
        baseToken = _baseToken;
        quoteToken = _quoteToken;
        pair = IUniswapV2Pair(_pair);
        require(address(pair) != address(0), "PriceStorage: INVALID_PAIR");
        require(
            (pair.token0() == baseToken && pair.token1() == quoteToken)
                || (pair.token0() == quoteToken && pair.token1() == baseToken),
            "PriceStorage: INVALID_BASE_TOKEN"
        );
        if (pair.totalSupply() > 0) {
            _syncPrice();
        }
    }

    function _initUsdtPair(address _usdtAddr, address _usdtPair) internal {
        usdtAddr = _usdtAddr;
        require(_usdtPair != address(0), "PriceStorage: INVALID_USDT_PAIR");
        usdtPair = IUniswapV2Pair(_usdtPair);
        require(usdtPair.token0() == quoteToken || usdtPair.token1() == quoteToken, "PriceStorage: INVALID_USDT_PAIR");
        require(usdtPair.token0() == usdtAddr || usdtPair.token1() == usdtAddr, "PriceStorage: INVALID_USDT_PAIR");
    }

    function getDailyOpenPrice(uint256 day) public view returns (PriceTime memory openPrice) {
        return _dailyOpenPrices[day];
    }

    function getLatestPrice() public view returns (PriceTime memory price) {
        return _latestPrice;
    }

    //计算当前价格
    function calcCurrentPrice() public view returns (uint256) {
        if (pair.totalSupply() <= 0) {
            return 0;
        }
        address token0 = pair.token0();
        (uint256 reserve0, uint256 reserve1,) = pair.getReserves();
        if (reserve0 == 0 || reserve1 == 0) {
            return 0;
        }
        uint256 price =
            token0 == baseToken ? (reserve1 * PRICE_DECIMALS) / reserve0 : (reserve0 * PRICE_DECIMALS) / reserve1;

        // 换算成U的价格
        token0 = usdtPair.token0();
        (reserve0, reserve1,) = usdtPair.getReserves();
        if (reserve0 == 0 || reserve1 == 0) {
            return 0;
        }
        uint256 usdtPrice = price * (token0 == quoteToken ? reserve1 / reserve0 : reserve0 / reserve1);

        return usdtPrice;
    }

    //获取今日开盘价
    function getTodayOpenPrice() public view returns (PriceTime memory) {
        uint256 todayTimestamp = (block.timestamp / 1 days) * 1 days;
        PriceTime memory priceTime = _dailyOpenPrices[todayTimestamp];
        if (priceTime.price == 0) {
            priceTime = _latestPrice;
        }
        return priceTime;
    }

    //获取涨跌幅（正数为涨，负数为跌）
    ///@dev 精度1e4
    function getPriceChange() public view returns (int256) {
        PriceTime memory todayOpenPrice = getTodayOpenPrice();
        if (todayOpenPrice.price == 0) {
            return 0;
        }
        int256 priceChange = int256(calcCurrentPrice()) - int256(todayOpenPrice.price);
        return (priceChange * 1e4) / int256(todayOpenPrice.price);
    }

    //同步当前价格
    function _syncPrice() internal returns (bool, uint256) {
        uint256 currentTimestamp = block.timestamp;
        uint256 todayTimestamp = (currentTimestamp / 1 days) * 1 days;
        uint256 currentPrice = calcCurrentPrice();
        if (currentPrice == 0) {
            return (false, 0);
        }
        PriceTime memory priceTime = PriceTime(currentPrice, currentTimestamp);
        if (_dailyOpenPrices[todayTimestamp].price == 0) {
            //今日开盘价为昨日收盘价
            _dailyOpenPrices[todayTimestamp] = _latestPrice;
            emit DailyOpenPrice(todayTimestamp, _latestPrice);
        }
        _latestPrice = priceTime;
        return (true, currentPrice);
    }

    function _adminSetOpenPrice(uint256 timestamp, uint256 price) internal {
        require(timestamp <= block.timestamp, "PriceStorage: INVALID_TIMESTAMP");
        if (timestamp == 0) {
            timestamp = block.timestamp;
        }
        _dailyOpenPrices[(timestamp / 1 days) * 1 days] = PriceTime(price, timestamp);
        emit DailyOpenPrice((timestamp / 1 days) * 1 days, PriceTime(price, timestamp));
        emit AdminSetOpenPrice(timestamp, price);
    }
}
