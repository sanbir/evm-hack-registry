// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

/*  GMX Synthetics — limit / stop orders revert on a price gap (Sherlock H-7, #18633)
    SYNTHETIC, cheatcode-free reduction for the EVM Playground.

    BaseOrderUtils.setExactOrderPrice requires the earlier oracle print and the
    later one to straddle the trigger. A long StopLossDecrease uses the
    descending check (shouldValidateAscendingPrice = !isLong = false):

        bool ok = primaryPrice >= triggerPrice && triggerPrice >= secondaryPrice;

    If the market gaps through the stop, both prints are already below the
    trigger, `ok` is false, and the order reverts with InvalidOrderPrices.
    The position stays open. At the gapped print the long's equity is 0, so
    the 2000 collateral stays in the book and the trader is paid 0.

    The report's fix is to not revert when both prints are worse than the
    trigger, and to execute at the trigger. That control pays the trader
    1500 and keeps only the 500 loss that the stop was meant to realize.
    A normal straddle (1950 then 1850 around 1900) still fills at 1900 on
    the vulnerable book, so the failure is the gap, not the fill price. */

library OrderErrors {
    error InvalidOrderPrices(
        uint256 primaryPrice,
        uint256 secondaryPrice,
        uint256 triggerPrice,
        bool shouldValidateAscendingPrice
    );
}

contract CollateralToken {
    mapping(address => uint256) public balanceOf;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        require(balanceOf[msg.sender] >= amount, "bal");
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

contract Trader {}

contract PositionBook {
    CollateralToken public token;
    address public trader;

    uint256 public entryPrice;
    uint256 public triggerPrice;
    uint256 public sizeUsd;
    uint256 public collateral;
    bool public isLong;
    bool public opened;

    uint256 public primaryPrice;
    uint256 public secondaryPrice;
    uint256 public primaryBlock;
    uint256 public secondaryBlock;
    uint256 public orderBlock;

    bool public filled;
    uint256 public executionPrice;
    uint256 public paid;

    constructor(CollateralToken _token, address _trader) {
        token = _token;
        trader = _trader;
    }

    function openLong(uint256 entry, uint256 size, uint256 coll, uint256 trigger, uint256 submittedBlock) external {
        require(!opened, "opened");
        require(size != 0 && coll != 0 && entry != 0 && trigger != 0, "params");
        require(trigger < entry, "stop below entry");
        entryPrice = entry;
        sizeUsd = size;
        collateral = coll;
        triggerPrice = trigger;
        orderBlock = submittedBlock;
        isLong = true;
        opened = true;
    }

    function setOracle(uint256 primary, uint256 secondary, uint256 primaryBlk, uint256 secondaryBlk) external {
        require(opened, "not open");
        require(primaryBlk > orderBlock, "primary block");
        require(secondaryBlk > primaryBlk, "secondary block");
        primaryPrice = primary;
        secondaryPrice = secondary;
        primaryBlock = primaryBlk;
        secondaryBlock = secondaryBlk;
    }

    function equityAt(uint256 price) public view returns (int256) {
        int256 pnl = int256(sizeUsd) * (int256(price) - int256(entryPrice)) / int256(entryPrice);
        return int256(collateral) + pnl;
    }

    function _fill(uint256 price) internal {
        int256 pnl = int256(sizeUsd) * (int256(price) - int256(entryPrice)) / int256(entryPrice);
        uint256 amount;
        if (pnl >= 0) {
            amount = collateral + uint256(pnl);
        } else {
            uint256 loss = uint256(-pnl);
            amount = loss >= collateral ? 0 : collateral - loss;
        }
        executionPrice = price;
        paid = amount;
        filled = true;
        sizeUsd = 0;
        collateral = 0;
        if (amount != 0) {
            token.transfer(trader, amount);
        }
    }
}

/// Vulnerable stop: the audited straddle. A gap below the trigger reverts.
contract LimitBook is PositionBook {
    constructor(CollateralToken _token, address _trader) PositionBook(_token, _trader) {}

    // BaseOrderUtils.setExactOrderPrice — StopLossDecrease, isLong == true.
    // shouldValidateAscendingPrice = !isLong = false, so the descending arm runs.
    function executeStop() external {
        require(opened, "not open");
        require(!filled, "filled");
        require(isLong, "long");
        require(primaryBlock > orderBlock, "primary block");
        require(secondaryBlock > orderBlock, "secondary block");
        uint256 primary = primaryPrice;
        uint256 secondary = secondaryPrice;
        uint256 trigger = triggerPrice;
        // @> VULN: both prints already below the trigger fail this straddle, so the stop reverts and does not fill
        bool ok = primary >= trigger && trigger >= secondary;
        if (!ok) {
            revert OrderErrors.InvalidOrderPrices(primary, secondary, trigger, false);
        }
        _fill(trigger);
    }
}

/// Report recommendation: a gap that is already worse than the trigger still
/// fills, and the execution price is the trigger, not the gapped print.
contract LimitBookFixed is PositionBook {
    constructor(CollateralToken _token, address _trader) PositionBook(_token, _trader) {}

    function executeStop() external {
        require(opened, "not open");
        require(!filled, "filled");
        require(isLong, "long");
        require(primaryBlock > orderBlock, "primary block");
        require(secondaryBlock > orderBlock, "secondary block");
        uint256 primary = primaryPrice;
        uint256 secondary = secondaryPrice;
        uint256 trigger = triggerPrice;
        bool straddles = primary >= trigger && trigger >= secondary;
        bool gappedWorse = primary < trigger && secondary < trigger;
        if (!straddles && !gappedWorse) {
            revert OrderErrors.InvalidOrderPrices(primary, secondary, trigger, false);
        }
        _fill(trigger);
    }
}

contract Exploit {
    uint256 public constant ENTRY = 2000 ether;
    uint256 public constant TRIGGER = 1900 ether;
    uint256 public constant SIZE = 10000 ether;
    uint256 public constant COLLATERAL = 2000 ether;
    uint256 public constant PRIMARY = 1700 ether;
    uint256 public constant SECONDARY = 1600 ether;
    uint256 public constant ORDER_BLOCK = 100;
    uint256 public constant PRIMARY_BLOCK = 101;
    uint256 public constant SECONDARY_BLOCK = 102;
    uint256 public constant STRADDLE_PRIMARY = 1950 ether;
    uint256 public constant STRADDLE_SECONDARY = 1850 ether;
    uint256 public constant FAIR_PAYOUT = 1500 ether;

    CollateralToken public token;
    Trader public trader;
    LimitBook public book;

    bytes4 public caught;
    uint256 public revertPrimary;
    uint256 public revertSecondary;
    uint256 public revertTrigger;
    bool public revertAscending;
    bool public filledFlag;
    uint256 public openSize;
    uint256 public fairEquity;
    uint256 public gapEquity;
    uint256 public stuck;
    uint256 public traderBal;

    bool public controlFilled;
    uint256 public controlPrice;
    uint256 public controlPaid;
    uint256 public controlTraderBal;
    uint256 public controlBookBal;
    uint256 public controlSize;

    constructor() {
        token = new CollateralToken();
        trader = new Trader();
        book = new LimitBook(token, address(trader));
    }

    function run() external {
        book.openLong(ENTRY, SIZE, COLLATERAL, TRIGGER, ORDER_BLOCK);
        token.mint(address(book), COLLATERAL);
        book.setOracle(PRIMARY, SECONDARY, PRIMARY_BLOCK, SECONDARY_BLOCK);
        try book.executeStop() {
            revert("gap filled");
        } catch (bytes memory reason) {
            (bytes4 sel, uint256 primary, uint256 secondary, uint256 trigger, bool ascending) = _decodeGap(reason);
            caught = sel;
            revertPrimary = primary;
            revertSecondary = secondary;
            revertTrigger = trigger;
            revertAscending = ascending;
        }
        require(caught == OrderErrors.InvalidOrderPrices.selector, "selector");
        require(revertPrimary == PRIMARY, "revert primary");
        require(revertSecondary == SECONDARY, "revert secondary");
        require(revertTrigger == TRIGGER, "revert trigger");
        require(revertAscending == false, "ascending");
        filledFlag = book.filled();
        openSize = book.sizeUsd();
        fairEquity = uint256(book.equityAt(TRIGGER));
        gapEquity = uint256(book.equityAt(SECONDARY));
        stuck = token.balanceOf(address(book));
        traderBal = token.balanceOf(address(trader));
        require(filledFlag == false, "filled");
        require(openSize == SIZE, "size");
        require(fairEquity == FAIR_PAYOUT, "fair");
        require(gapEquity == 0, "gap equity");
        require(stuck == COLLATERAL, "stuck");
        require(traderBal == 0, "trader paid");
    }

    /// Same gap, fixed check. The stop fills at the trigger and pays 1500.
    function runControl() external {
        LimitBookFixed fixedBook = new LimitBookFixed(token, address(trader));
        fixedBook.openLong(ENTRY, SIZE, COLLATERAL, TRIGGER, ORDER_BLOCK);
        token.mint(address(fixedBook), COLLATERAL);
        fixedBook.setOracle(PRIMARY, SECONDARY, PRIMARY_BLOCK, SECONDARY_BLOCK);
        fixedBook.executeStop();
        controlFilled = fixedBook.filled();
        controlPrice = fixedBook.executionPrice();
        controlPaid = fixedBook.paid();
        controlTraderBal = token.balanceOf(address(trader));
        controlBookBal = token.balanceOf(address(fixedBook));
        controlSize = fixedBook.sizeUsd();
        require(controlFilled, "control filled");
        require(controlPrice == TRIGGER, "control price");
        require(controlPaid == FAIR_PAYOUT, "control paid");
        require(controlTraderBal == FAIR_PAYOUT, "control trader");
        require(controlBookBal == COLLATERAL - FAIR_PAYOUT, "control book");
        require(controlSize == 0, "control size");
    }

    /// Prices that do straddle the trigger still fill at the trigger.
    function runStraddle() external {
        book.openLong(ENTRY, SIZE, COLLATERAL, TRIGGER, ORDER_BLOCK);
        token.mint(address(book), COLLATERAL);
        book.setOracle(STRADDLE_PRIMARY, STRADDLE_SECONDARY, PRIMARY_BLOCK, SECONDARY_BLOCK);
        book.executeStop();
        require(book.filled(), "straddle filled");
        require(book.executionPrice() == TRIGGER, "straddle price");
        require(book.paid() == FAIR_PAYOUT, "straddle paid");
        require(book.sizeUsd() == 0, "straddle size");
        require(token.balanceOf(address(trader)) == FAIR_PAYOUT, "straddle trader");
    }

    function _decodeGap(bytes memory reason)
        internal
        pure
        returns (bytes4 sel, uint256 primary, uint256 secondary, uint256 trigger, bool ascending)
    {
        require(reason.length == 4 + 32 * 4, "len");
        uint256 flag;
        assembly {
            sel := mload(add(reason, 32))
            primary := mload(add(reason, 36))
            secondary := mload(add(reason, 68))
            trigger := mload(add(reason, 100))
            flag := mload(add(reason, 132))
        }
        ascending = flag != 0;
    }
}
