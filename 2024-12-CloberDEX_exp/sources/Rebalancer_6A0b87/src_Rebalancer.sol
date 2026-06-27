// SPDX-License-Identifier: GPL-2.0-or-later

pragma solidity ^0.8.0;

import {Ownable2Step, Ownable} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {IERC20, SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {IBookManager} from "clober-dex/v2-core/interfaces/IBookManager.sol";
import {ILocker} from "clober-dex/v2-core/interfaces/ILocker.sol";
import {BookId, BookIdLibrary} from "clober-dex/v2-core/libraries/BookId.sol";
import {Currency, CurrencyLibrary} from "clober-dex/v2-core/libraries/Currency.sol";
import {OrderId, OrderIdLibrary} from "clober-dex/v2-core/libraries/OrderId.sol";
import {Tick, TickLibrary} from "clober-dex/v2-core/libraries/Tick.sol";
import {FeePolicy, FeePolicyLibrary} from "clober-dex/v2-core/libraries/FeePolicy.sol";
import {FixedPointMathLib} from "solmate/utils/FixedPointMathLib.sol";

import {IRebalancer} from "./interfaces/IRebalancer.sol";
import {IStrategy} from "./interfaces/IStrategy.sol";
import {ERC6909Supply} from "./libraries/ERC6909Supply.sol";

contract Rebalancer is IRebalancer, ILocker, Ownable2Step, ERC6909Supply {
    using BookIdLibrary for IBookManager.BookKey;
    using SafeERC20 for IERC20;
    using SafeCast for uint256;
    using CurrencyLibrary for Currency;
    using OrderIdLibrary for OrderId;
    using TickLibrary for Tick;
    using FeePolicyLibrary for FeePolicy;

    uint256 public constant RATE_PRECISION = 1e6;

    IBookManager public immutable bookManager;

    mapping(bytes32 key => Pool) private _pools;
    mapping(BookId => BookId) public bookPair;

    modifier selfOnly() {
        if (msg.sender != address(this)) revert NotSelf();
        _;
    }

    constructor(IBookManager bookManager_, address initialOwner_) Ownable(initialOwner_) {
        bookManager = bookManager_;
    }

    function decimals(uint256) external pure returns (uint8) {
        return 18;
    }

    function getPool(bytes32 key) external view returns (Pool memory) {
        return _pools[key];
    }

    function getBookPairs(bytes32 key) external view returns (BookId, BookId) {
        return (_pools[key].bookIdA, _pools[key].bookIdB);
    }

    function getLiquidity(bytes32 key) public view returns (Liquidity memory liquidityA, Liquidity memory liquidityB) {
        Pool storage pool = _pools[key];
        liquidityA.reserve = pool.reserveA;
        liquidityB.reserve = pool.reserveB;

        OrderId[] memory orderListA = pool.orderListA;
        OrderId[] memory orderListB = pool.orderListB;

        if (orderListA.length > 0) {
            IBookManager.BookKey memory bookKeyA = bookManager.getBookKey(pool.bookIdA);
            for (uint256 i; i < orderListA.length; ++i) {
                (uint256 cancelable, uint256 claimable) =
                    _getLiquidity(bookKeyA.makerPolicy, bookKeyA.unitSize, orderListA[i]);
                liquidityA.cancelable += cancelable;
                liquidityB.claimable += claimable;
            }
        }
        if (orderListB.length > 0) {
            IBookManager.BookKey memory bookKeyB = bookManager.getBookKey(pool.bookIdB);
            for (uint256 i; i < orderListB.length; ++i) {
                (uint256 cancelable, uint256 claimable) =
                    _getLiquidity(bookKeyB.makerPolicy, bookKeyB.unitSize, orderListB[i]);
                liquidityA.claimable += claimable;
                liquidityB.cancelable += cancelable;
            }
        }
    }

    function _getLiquidity(FeePolicy makerPolicy, uint64 unitSize, OrderId orderId)
        internal
        view
        returns (uint256 cancelable, uint256 claimable)
    {
        IBookManager.OrderInfo memory orderInfo = bookManager.getOrder(orderId);
        cancelable = uint256(orderInfo.open) * unitSize;
        claimable = orderId.getTick().quoteToBase(uint256(orderInfo.claimable) * unitSize, false);
        if (makerPolicy.usesQuote()) {
            int256 fee = makerPolicy.calculateFee(cancelable, true);
            cancelable = uint256(int256(cancelable) + fee);
        } else {
            int256 fee = makerPolicy.calculateFee(claimable, false);
            claimable = uint256(int256(claimable) - fee);
        }
    }

    function open(
        IBookManager.BookKey calldata bookKeyA,
        IBookManager.BookKey calldata bookKeyB,
        bytes32 salt,
        address strategy
    ) external returns (bytes32) {
        return abi.decode(
            bookManager.lock(
                address(this), abi.encodeWithSelector(this._open.selector, bookKeyA, bookKeyB, salt, strategy)
            ),
            (bytes32)
        );
    }

    function mint(bytes32 key, uint256 amountA, uint256 amountB, uint256 minLpAmount)
        external
        payable
        returns (uint256 mintAmount)
    {
        Pool storage pool = _pools[key];
        IBookManager.BookKey memory bookKeyA = bookManager.getBookKey(pool.bookIdA);

        uint256 supply = totalSupply[uint256(key)];
        if (supply == 0) {
            if (amountA == 0 || amountB == 0) revert InvalidAmount();
            // @dev If the decimals > 18, it will revert.
            uint256 complementA =
                bookKeyA.quote.isNative() ? 1 : 10 ** (18 - IERC20Metadata(Currency.unwrap(bookKeyA.quote)).decimals());
            uint256 complementB =
                bookKeyA.base.isNative() ? 1 : 10 ** (18 - IERC20Metadata(Currency.unwrap(bookKeyA.base)).decimals());
            uint256 _amountA = amountA * complementA;
            uint256 _amountB = amountB * complementB;
            mintAmount = _amountA > _amountB ? _amountA : _amountB;
        } else {
            (Liquidity memory liquidityA, Liquidity memory liquidityB) = getLiquidity(key);
            uint256 totalLiquidityA = liquidityA.reserve + liquidityA.claimable + liquidityA.cancelable;
            uint256 totalLiquidityB = liquidityB.reserve + liquidityB.claimable + liquidityB.cancelable;

            if (totalLiquidityA == 0 && totalLiquidityB == 0) {
                mintAmount = amountA = amountB = 0;
            } else if (totalLiquidityA == 0) {
                mintAmount = FixedPointMathLib.mulDivDown(amountB, supply, totalLiquidityB);
                amountA = 0;
            } else if (totalLiquidityB == 0) {
                mintAmount = FixedPointMathLib.mulDivDown(amountA, supply, totalLiquidityA);
                amountB = 0;
            } else {
                uint256 mintA = FixedPointMathLib.mulDivDown(amountA, supply, totalLiquidityA);
                uint256 mintB = FixedPointMathLib.mulDivDown(amountB, supply, totalLiquidityB);
                if (mintA > mintB) {
                    mintAmount = mintB;
                    amountA = FixedPointMathLib.mulDivUp(totalLiquidityA, mintAmount, supply);
                } else {
                    mintAmount = mintA;
                    amountB = FixedPointMathLib.mulDivUp(totalLiquidityB, mintAmount, supply);
                }
            }
        }
        if (mintAmount < minLpAmount) revert Slippage();

        uint256 refund = msg.value;
        if (bookKeyA.quote.isNative()) {
            if (msg.value < amountA) {
                revert InvalidValue();
            } else {
                unchecked {
                    refund -= amountA;
                }
            }
        } else {
            IERC20(Currency.unwrap(bookKeyA.quote)).safeTransferFrom(msg.sender, address(this), amountA);
        }
        if (bookKeyA.base.isNative()) {
            if (msg.value < amountB) {
                revert InvalidValue();
            } else {
                unchecked {
                    refund -= amountB;
                }
            }
        } else {
            IERC20(Currency.unwrap(bookKeyA.base)).safeTransferFrom(msg.sender, address(this), amountB);
        }

        pool.reserveA += amountA;
        pool.reserveB += amountB;

        _mint(msg.sender, uint256(key), mintAmount);
        pool.strategy.mintHook(msg.sender, key, mintAmount, supply);
        emit Mint(msg.sender, key, amountA, amountB, mintAmount);

        if (refund > 0) {
            CurrencyLibrary.NATIVE.transfer(msg.sender, refund);
        }
    }

    function burn(bytes32 key, uint256 amount, uint256 minAmountA, uint256 minAmountB)
        external
        returns (uint256 withdrawalA, uint256 withdrawalB)
    {
        (withdrawalA, withdrawalB) = abi.decode(
            bookManager.lock(address(this), abi.encodeWithSelector(this._burn.selector, key, msg.sender, amount)),
            (uint256, uint256)
        );
        if (withdrawalA < minAmountA || withdrawalB < minAmountB) revert Slippage();
    }

    function rebalance(bytes32 key) public {
        bookManager.lock(address(this), abi.encodeWithSelector(this._rebalance.selector, key));
    }

    function lockAcquired(address lockCaller, bytes calldata data) external returns (bytes memory) {
        if (msg.sender != address(bookManager)) revert InvalidLockAcquiredSender();
        if (lockCaller != address(this)) revert InvalidLockCaller();

        (bool success, bytes memory returnData) = address(this).call(data);
        if (success) return returnData;
        if (returnData.length == 0) revert LockFailure();
        // if the call failed, bubble up the reason
        /// @solidity memory-safe-assembly
        assembly {
            revert(add(returnData, 32), mload(returnData))
        }
    }

    function _open(
        IBookManager.BookKey calldata bookKeyA,
        IBookManager.BookKey calldata bookKeyB,
        bytes32 salt,
        address strategy
    ) public selfOnly returns (bytes32 key) {
        if (
            !(bookKeyA.quote.equals(bookKeyB.base) && bookKeyA.base.equals(bookKeyB.quote))
                || bookKeyA.quote.equals(bookKeyA.base)
        ) revert InvalidBookPair();
        if (address(bookKeyA.hooks) != address(0) || address(bookKeyB.hooks) != address(0)) revert InvalidHook();
        if (strategy == address(0)) revert InvalidStrategy();

        BookId bookIdA = bookKeyA.toId();
        BookId bookIdB = bookKeyB.toId();
        if (!bookManager.isOpened(bookIdA)) bookManager.open(bookKeyA, "");
        if (!bookManager.isOpened(bookIdB)) bookManager.open(bookKeyB, "");

        key = _encodeKey(bookIdA, bookIdB, salt);
        if (_pools[key].strategy != IStrategy(address(0))) revert AlreadyOpened();

        _pools[key].bookIdA = bookIdA;
        _pools[key].bookIdB = bookIdB;
        _pools[key].strategy = IStrategy(strategy);
        bookPair[bookIdA] = bookIdB;
        bookPair[bookIdB] = bookIdA;

        emit Open(key, bookIdA, bookIdB, salt, strategy);
    }

    function _burn(bytes32 key, address user, uint256 burnAmount)
        public
        selfOnly
        returns (uint256 withdrawalA, uint256 withdrawalB)
    {
        Pool storage pool = _pools[key];
        uint256 supply = totalSupply[uint256(key)];

        (uint256 canceledAmountA, uint256 canceledAmountB, uint256 claimedAmountA, uint256 claimedAmountB) =
            _clearPool(key, pool, burnAmount, supply);

        uint256 reserveA = pool.reserveA;
        uint256 reserveB = pool.reserveB;

        withdrawalA = (reserveA + claimedAmountA) * burnAmount / supply + canceledAmountA;
        withdrawalB = (reserveB + claimedAmountB) * burnAmount / supply + canceledAmountB;

        _burn(user, uint256(key), burnAmount);
        pool.strategy.burnHook(msg.sender, key, burnAmount, supply);
        emit Burn(user, key, withdrawalA, withdrawalB, burnAmount);

        IBookManager.BookKey memory bookKeyA = bookManager.getBookKey(pool.bookIdA);

        pool.reserveA = _settleCurrency(bookKeyA.quote, reserveA) - withdrawalA;
        pool.reserveB = _settleCurrency(bookKeyA.base, reserveB) - withdrawalB;

        if (withdrawalA > 0) {
            bookKeyA.quote.transfer(user, withdrawalA);
        }
        if (withdrawalB > 0) {
            bookKeyA.base.transfer(user, withdrawalB);
        }
    }

    function _rebalance(bytes32 key) public selfOnly {
        Pool storage pool = _pools[key];
        uint256 reserveA = pool.reserveA;
        uint256 reserveB = pool.reserveB;
        IBookManager.BookKey memory bookKeyA = bookManager.getBookKey(pool.bookIdA);
        IBookManager.BookKey memory bookKeyB = bookManager.getBookKey(pool.bookIdB);

        // Compute allocation
        try pool.strategy.computeOrders(key) returns (
            IStrategy.Order[] memory liquidityA, IStrategy.Order[] memory liquidityB
        ) {
            if (liquidityA.length == 0 && liquidityB.length == 0) return;
            _clearPool(key, pool, 1, 1);

            _setLiquidity(bookKeyA, liquidityA, pool.orderListA);
            _setLiquidity(bookKeyB, liquidityB, pool.orderListB);

            pool.strategy.rebalanceHook(msg.sender, key, liquidityA, liquidityB);
            emit Rebalance(key);
        } catch {
            _clearPool(key, pool, 1, 1);
        }

        pool.reserveA = _settleCurrency(bookKeyA.quote, reserveA);
        pool.reserveB = _settleCurrency(bookKeyA.base, reserveB);
    }

    function _clearPool(bytes32 key, Pool storage pool, uint256 cancelNumerator, uint256 cancelDenominator)
        internal
        returns (uint256 canceledAmountA, uint256 canceledAmountB, uint256 claimedAmountA, uint256 claimedAmountB)
    {
        (canceledAmountA, claimedAmountB) = _clearOrders(pool.orderListA, cancelNumerator, cancelDenominator);
        (canceledAmountB, claimedAmountA) = _clearOrders(pool.orderListB, cancelNumerator, cancelDenominator);
        emit Claim(key, claimedAmountA, claimedAmountB);
        emit Cancel(key, canceledAmountA, canceledAmountB);
    }

    function _clearOrders(OrderId[] storage orderIds, uint256 cancelNumerator, uint256 cancelDenominator)
        internal
        returns (uint256 canceledAmount, uint256 claimedAmount)
    {
        OrderId[] memory mOrderIds = orderIds;
        for (uint256 i = 0; i < mOrderIds.length; ++i) {
            OrderId orderId = mOrderIds[i];
            IBookManager.OrderInfo memory orderInfo = bookManager.getOrder(orderId);
            if (orderInfo.claimable > 0) {
                claimedAmount += bookManager.claim(orderId, "");
            }
            if (orderInfo.open > 0) {
                canceledAmount += bookManager.cancel(
                    IBookManager.CancelParams({
                        id: orderId,
                        toUnit: (orderInfo.open - orderInfo.open * cancelNumerator / cancelDenominator).toUint64()
                    }),
                    ""
                );
            }
        }
        if (cancelDenominator == cancelNumerator) {
            assembly {
                sstore(orderIds.slot, 0)
            }
        }
    }

    function _setLiquidity(
        IBookManager.BookKey memory bookKey,
        IStrategy.Order[] memory liquidity,
        OrderId[] storage emptyOrderIds
    ) internal {
        for (uint256 i = 0; i < liquidity.length; ++i) {
            if (liquidity[i].rawAmount == 0) continue;
            (OrderId orderId,) = bookManager.make(
                IBookManager.MakeParams({
                    key: bookKey,
                    tick: liquidity[i].tick,
                    unit: liquidity[i].rawAmount,
                    provider: address(0)
                }),
                ""
            );
            emptyOrderIds.push(orderId);
        }
    }

    function _settleCurrency(Currency currency, uint256 liquidity) internal returns (uint256) {
        bookManager.settle(currency);

        int256 delta = bookManager.getCurrencyDelta(address(this), currency);
        if (delta > 0) {
            bookManager.withdraw(currency, address(this), uint256(delta));
            liquidity += uint256(delta);
        } else if (delta < 0) {
            currency.transfer(address(bookManager), uint256(-delta));
            bookManager.settle(currency);
            liquidity -= uint256(-delta);
        }
        return liquidity;
    }

    function _encodeKey(BookId bookIdA, BookId bookIdB, bytes32 salt) internal pure returns (bytes32) {
        if (BookId.unwrap(bookIdA) > BookId.unwrap(bookIdB)) (bookIdA, bookIdB) = (bookIdB, bookIdA);
        return keccak256(abi.encodePacked(bookIdA, bookIdB, salt));
    }

    receive() external payable {}
}
