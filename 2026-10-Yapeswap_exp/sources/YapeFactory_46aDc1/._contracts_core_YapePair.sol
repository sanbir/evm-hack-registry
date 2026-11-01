// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity >=0.8.0;
pragma abicoder v2;

import {SafeMath} from "@openzeppelin/contracts/utils/math/SafeMath.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {UniswapV2Pair} from "../helpers/uni-v2/UniswapV2Pair.sol";
import {IUniswapV2Factory} from "../helpers/uni-v2/interfaces/IUniswapV2Factory.sol";
import {UQ112x112} from "../helpers/uni-v2/libraries/UQ112x112.sol";
import {RegistryAPI} from "../helpers/yearn/BaseWrapper.sol";
import {YapeWrapper} from "./YapeWrapper.sol";
import {IYapePair} from "../interfaces/IYapePair.sol";
import {IYapeFactory} from "../interfaces/IYapeFactory.sol";

contract YapePair is UniswapV2Pair, YapeWrapper {
    using SafeMath for uint256;
    using SafeERC20 for IERC20;
    using UQ112x112 for uint224;

    mapping(address => uint256) public farming;

    uint256 private _minFarming;
    uint256 private _maxFarming;
    address private _registry;
    uint256 private constant DENOMINATOR = 10000;

    event YearnDeposit(address token, uint256 amount);
    event YearnWithdraw(address token, uint256 amount, uint256 yield);

    modifier onlyOperator() {
        require(msg.sender == IYapeFactory(factory).operator());
        _;
    }

    modifier onlyReserved(address token) {
        require(
            token == token0 || token == token1,
            "Yapeswap: NOT A RESERVED TOKEN"
        );
        _;
    }

    modifier keepBalance(address token) {
        uint256 prevBal = _balanceOf(token);
        _;
        require(_balanceOf(token) == prevBal, "Yapeswap: BALANCE CHANGED");
    }

    function mint(address to) public override returns (uint256 liquidity) {
        liquidity = super.mint(to);
        _rebalance(token0, 0, false);
        _rebalance(token1, 0, false);
    }

    function updateRegistry() public {
        _registry = IYapeFactory(factory).registry();
    }

    function setFarmingRatio(uint256 min, uint256 max) external onlyOperator {
        require(max <= DENOMINATOR);
        require(min <= max);
        _minFarming = min;
        _maxFarming = max;
    }

    /**
     * @param token use token0 or token1
     * @param amount use type(uint256).max (when you want to migrate all)
     * @param maxMigrationLoss use 0 for the default value
     */
    function migrate(
        address token,
        uint256 amount,
        uint256 maxMigrationLoss
    ) external onlyOperator onlyReserved(token) returns (uint256) {
        return _migrate(token, address(this), amount, maxMigrationLoss);
    }

    function rebalance(address token) external onlyReserved(token) {
        _rebalance(token, 0, true);
    }

    function registry() public view override returns (RegistryAPI) {
        return RegistryAPI(_registry);
    }

    function farmingRatio() public view returns (uint256 min, uint256 max) {
        return (_minFarming, _maxFarming);
    }

    function name() public view override returns (string memory) {
        return "Yape LP";
    }

    function symbol() public view override returns (string memory) {
        return "YLP";
    }

    function _balanceOf(address token)
        internal
        view
        override
        returns (uint256)
    {
        return IERC20(token).balanceOf(address(this)).add(farming[token]);
    }

    function _safeTransfer(
        address token,
        address to,
        uint256 value
    ) internal override {
        _rebalance(token, value, false);
        (bool success, bytes memory data) = token.call(
            abi.encodeWithSelector(SELECTOR, to, value)
        );
        require(
            success && (data.length == 0 || abi.decode(data, (bool))),
            "UniswapV2: TRANSFER_FAILED"
        );
    }

    function _rebalance(
        address token,
        uint256 amountOut,
        bool force
    ) internal {
        uint256 newBal = _balanceOf(token).sub(amountOut);
        uint256 minFarming = newBal.mul(_minFarming).div(DENOMINATOR);
        uint256 maxFarming = newBal.mul(_maxFarming).div(DENOMINATOR);
        uint256 currentFarming = farming[token];
        uint256 avg = Math.average(minFarming, maxFarming);
        if (currentFarming > maxFarming || (force && currentFarming > avg)) {
            // should withdraw from Yearn
            _fromYearn(token, currentFarming - avg);
        } else if (
            minFarming > currentFarming || (force && avg > currentFarming)
        ) {
            // should deposit to Yearn
            _toYearn(token, avg - currentFarming);
        }
    }

    function _toYearn(address token, uint256 amount)
        internal
        keepBalance(token)
    {
        uint256 deposited = _deposit(
            token,
            address(this),
            address(this),
            amount,
            false
        );
        farming[token] = farming[token].add(deposited);
        emit YearnDeposit(token, amount);
    }

    function _fromYearn(address token, uint256 amount)
        internal
        keepBalance(token)
    {
        uint256 yearnBal = totalVaultBalance(token, address(this));
        uint256 farmingAmount = farming[token];
        uint256 yield;
        if (yearnBal > farmingAmount) {
            yield = yearnBal - farmingAmount;
        } else {
            // rare case
            yield = 0;
        }
        uint256 withdrawn = _withdraw(
            token,
            address(this),
            address(this),
            amount.add(yield),
            true
        );
        uint256 netYield;
        if (withdrawn > amount) {
            netYield = withdrawn - amount;
        } else {
            netYield = 0;
        }
        farming[token] = farmingAmount.sub(withdrawn - netYield);
        // Send fee
        address feeTo = IUniswapV2Factory(factory).feeTo();
        if (netYield > 0) {
            IERC20(token).safeTransfer(feeTo, netYield);
        }
        emit YearnWithdraw(token, withdrawn, netYield);
    }
}
