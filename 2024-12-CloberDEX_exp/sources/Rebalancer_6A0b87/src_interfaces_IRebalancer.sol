// SPDX-License-Identifier: GPL-2.0-or-later

pragma solidity ^0.8.0;

import {IBookManager} from "clober-dex/v2-core/interfaces/IBookManager.sol";
import {BookId} from "clober-dex/v2-core/libraries/BookId.sol";
import {BookId} from "clober-dex/v2-core/libraries/BookId.sol";
import {OrderId} from "clober-dex/v2-core/libraries/OrderId.sol";

import {IStrategy} from "./IStrategy.sol";

interface IRebalancer {
    struct Pool {
        BookId bookIdA;
        BookId bookIdB;
        IStrategy strategy;
        uint256 reserveA;
        uint256 reserveB;
        OrderId[] orderListA;
        OrderId[] orderListB;
    }

    error NotSelf();
    error InvalidHook();
    error InvalidStrategy();
    error InvalidBookPair();
    error AlreadyOpened();
    error InvalidLockAcquiredSender();
    error InvalidLockCaller();
    error LockFailure();
    error InvalidMaker();
    error InvalidAmount();
    error InvalidValue();
    error Slippage();

    event Open(bytes32 indexed key, BookId indexed bookIdA, BookId indexed bookIdB, bytes32 salt, address strategy);
    event Mint(address indexed user, bytes32 indexed key, uint256 amountA, uint256 amountB, uint256 lpAmount);
    event Burn(address indexed user, bytes32 indexed key, uint256 amountA, uint256 amountB, uint256 lpAmount);
    event Rebalance(bytes32 indexed key);
    event Claim(bytes32 indexed key, uint256 claimedAmountA, uint256 claimedAmountB);
    event Cancel(bytes32 indexed key, uint256 canceledAmountA, uint256 canceledAmountB);

    struct Liquidity {
        uint256 reserve;
        uint256 claimable;
        uint256 cancelable;
    }

    /**
     * @notice Retrieves the book pair for a specified book ID.
     * @param bookId The book ID.
     * @return The book pair.
     */
    function bookPair(BookId bookId) external view returns (BookId);

    /**
     * @notice Retrieves the pool for a specified key.
     * @param key The key of the pool.
     * @return The pool.
     */
    function getPool(bytes32 key) external view returns (Pool memory);

    /**
     * @notice Retrieves the book pairs for a specified key.
     * @param key The key of the pool.
     * @return bookIdA The book ID for the first book.
     * @return bookIdB The book ID for the second book.
     */
    function getBookPairs(bytes32 key) external view returns (BookId bookIdA, BookId bookIdB);

    /**
     * @notice Retrieves the liquidity for a specified key.
     * @param key The key of the pool.
     * @return liquidityA The liquidity for the first token.
     * @return liquidityB The liquidity for the second token.
     */
    function getLiquidity(bytes32 key)
        external
        view
        returns (Liquidity memory liquidityA, Liquidity memory liquidityB);

    /**
     * @notice Opens a new pool with the specified parameters.
     * @param bookKeyA The book key for the first book.
     * @param bookKeyB The book key for the second book.
     * @param salt The salt value.
     * @param strategy The address of the strategy.
     * @return key The key of the opened pool.
     */
    function open(
        IBookManager.BookKey calldata bookKeyA,
        IBookManager.BookKey calldata bookKeyB,
        bytes32 salt,
        address strategy
    ) external returns (bytes32 key);

    /**
     * @notice Mints liquidity for the specified key.
     * @param key The key of the pool.
     * @param amountA The amount of the first token.
     * @param amountB The amount of the second token.
     * @param minLpAmount The minimum amount of liquidity tokens to mint.
     * @return The amount of liquidity tokens minted.
     */
    function mint(bytes32 key, uint256 amountA, uint256 amountB, uint256 minLpAmount)
        external
        payable
        returns (uint256);

    /**
     * @notice Burns liquidity for the specified key.
     * @param key The key of the pool.
     * @param amount The amount of liquidity tokens to burn.
     * @param minAmountA The amount of the first token to receive.
     * @param minAmountB The minimum amount of the second token to receive.
     * @return The amounts of the first and second tokens to receive.
     */
    function burn(bytes32 key, uint256 amount, uint256 minAmountA, uint256 minAmountB)
        external
        returns (uint256, uint256);

    /**
     * @notice Rebalances the pool for the specified key.
     * @param key The key of the pool.
     */
    function rebalance(bytes32 key) external;
}
