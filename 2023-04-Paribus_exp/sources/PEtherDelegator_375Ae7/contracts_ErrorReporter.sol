// SPDX-License-Identifier: BSD-3-Clause
pragma solidity ^0.5.17;

contract ComptrollerErrorReporter {
    enum Error {
        NO_ERROR, // 0
        COMPTROLLER_MISMATCH, // 1
        INSUFFICIENT_SHORTFALL, // 2
        INSUFFICIENT_LIQUIDITY, // 3
        INVALID_COLLATERAL_FACTOR, // 4
        MARKET_NOT_ENTERED, // 5
        MARKET_NOT_LISTED, // 6
        MARKET_ALREADY_LISTED, // 7
        NONZERO_BORROW_BALANCE, // 8
        PRICE_ERROR, // 9
        REJECTION, // 10
        TOO_MUCH_REPAY, // 11
        NFT_USER_NOT_ALLOWED // 12
    }

    enum FailureInfo {
        EXIT_MARKET_BALANCE_OWED, // 0
        EXIT_MARKET_REJECTION, // 1
        SET_COLLATERAL_FACTOR_NO_EXISTS, // 2
        SET_COLLATERAL_FACTOR_VALIDATION, // 3
        SET_COLLATERAL_FACTOR_WITHOUT_PRICE, // 4
        SUPPORT_MARKET_EXISTS // 5
    }

    /**
      * @dev `error` corresponds to enum Error; `info` corresponds to enum FailureInfo, and `detail` is an arbitrary
      * contract-specific code that enables us to report opaque error codes from upgradeable contracts.
      **/
    event Failure(uint error, uint info, uint detail);

    /**
      * @dev use this when reporting a known error from the money market or a non-upgradeable collaborator
      */
    function fail(Error err, FailureInfo info) internal returns (uint) {
        emit Failure(uint(err), uint(info), 0);

        return uint(err);
    }

    /**
      * @dev use this when reporting an opaque error from an upgradeable collaborator contract
      */
    function failOpaque(Error err, FailureInfo info, uint opaqueError) internal returns (uint) {
        emit Failure(uint(err), uint(info), opaqueError);

        return uint(err);
    }
}

contract TokenErrorReporter {
    enum Error {
        NO_ERROR, // 0
        BAD_INPUT, // 1
        COMPTROLLER_REJECTION, // 2
        INVALID_ACCOUNT_PAIR, // 3
        INVALID_CLOSE_AMOUNT_REQUESTED, // 4
        MARKET_NOT_FRESH, // 5
        TOKEN_INSUFFICIENT_CASH // 6
    }

    enum FailureInfo {
        BORROW_CASH_NOT_AVAILABLE, // 0
        BORROW_FRESHNESS_CHECK, // 1
        BORROW_COMPTROLLER_REJECTION, // 2
        LIQUIDATE_COLLATERAL_FRESHNESS_CHECK, // 3
        LIQUIDATE_COMPTROLLER_REJECTION, // 4
        LIQUIDATE_CLOSE_AMOUNT_IS_UINT_MAX, // 5
        LIQUIDATE_CLOSE_AMOUNT_IS_ZERO, // 6
        LIQUIDATE_FRESHNESS_CHECK, // 7
        LIQUIDATE_LIQUIDATOR_IS_BORROWER, // 8
        LIQUIDATE_REPAY_BORROW_FRESH_FAILED, // 9
        LIQUIDATE_SEIZE_COMPTROLLER_REJECTION, // 10
        LIQUIDATE_SEIZE_LIQUIDATOR_IS_BORROWER, // 11
        MINT_COMPTROLLER_REJECTION, // 12
        MINT_FRESHNESS_CHECK, // 13
        REDEEM_COMPTROLLER_REJECTION, // 14
        REDEEM_TRANSFER_OUT_NOT_POSSIBLE, // 15
        REDEEM_FRESHNESS_CHECK, // 16
        REDUCE_RESERVES_CASH_NOT_AVAILABLE, // 17
        REDUCE_RESERVES_FRESH_CHECK, // 18
        REDUCE_RESERVES_VALIDATION, // 19
        REPAY_BORROW_COMPTROLLER_REJECTION, // 20
        REPAY_BORROW_FRESHNESS_CHECK, // 21
        SET_INTEREST_RATE_MODEL_FRESH_CHECK, // 22
        SET_RESERVE_FACTOR_FRESH_CHECK, // 23
        SET_RESERVE_FACTOR_BOUNDS_CHECK, // 24
        TRANSFER_COMPTROLLER_REJECTION, // 25
        TRANSFER_NOT_ALLOWED, // 26
        ADD_RESERVES_FRESH_CHECK // 27
    }

    /**
      * @dev `error` corresponds to enum Error; `info` corresponds to enum FailureInfo, and `detail` is an arbitrary
      * contract-specific code that enables us to report opaque error codes from upgradeable contracts.
      **/
    event Failure(uint error, uint info, uint detail);

    /**
      * @dev use this when reporting a known error from the money market or a non-upgradeable collaborator
      */
    function fail(Error err, FailureInfo info) internal returns (uint) {
        emit Failure(uint(err), uint(info), 0);

        return uint(err);
    }

    /**
      * @dev use this when reporting an opaque error from an upgradeable collaborator contract
      */
    function failOpaque(Error err, FailureInfo info, uint opaqueError) internal returns (uint) {
        emit Failure(uint(err), uint(info), opaqueError);

        return uint(err);
    }
}
