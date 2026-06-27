// SPDX-License-Identifier: BSD-3-Clause
pragma solidity ^0.5.17;

contract ErrorReporter {
    event Failure(uint error);

    enum Error {
        NO_ERROR, // 0
        COMPTROLLER_MISMATCH, // 1
        INSUFFICIENT_SHORTFALL, // 2
        INSUFFICIENT_LIQUIDITY, // 3
        MARKET_NOT_LISTED, // 4
        NONZERO_BORROW_BALANCE, // 5
        PRICE_ERROR, // 6
        TOO_MUCH_REPAY, // 7
        NFT_USER_NOT_ALLOWED, // 8
        INVALID_EXCHANGE_PTOKEN, // 9
        USER_NOT_IN_MARKET, // 10
        TOKEN_INSUFFICIENT_CASH, // 11
        NON_WHITE_LISTED_POOL // 12
    }

    function fail(Error err) internal returns (Error) {
        assert(err != Error.NO_ERROR);
        emit Failure(uint(err));
        return err;
    }
}
