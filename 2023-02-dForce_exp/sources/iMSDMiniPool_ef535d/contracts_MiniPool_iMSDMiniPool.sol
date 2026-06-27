// SPDX-License-Identifier: MIT
pragma solidity 0.6.12;

import "../msd/iMSD.sol";
import "../iToken.sol";

/**
 * @title dForce's Lending Protocol Contract.
 * @notice dForce lending token for the Mini Pool.
 * @author dForce Team.
 */
contract iMSDMiniPool is iMSD {
    using SafeERC20Upgradeable for IERC20Upgradeable;

    iToken public collateral;
    IERC20Upgradeable public collateralUnderlying;

    address public originationFeeRecipient;
    uint256 public originationFeeRatio;

    uint256 constant MAX_FEE_RATIO = 0.5e18;

    event NewOriginationFeeRecipient(
        address oldOriginationFeeRecipient,
        address newOriginationFeeRecipient
    );
    event NewOriginationFeeRatio(
        uint256 oldOriginationFeeRatio,
        uint256 newOriginationFeeRatio
    );

    /**
     * @notice Expects to call only once to initialize a new market.
     * @param _underlyingToken The underlying token address.
     * @param _name Token name.
     * @param _symbol Token symbol.
     * @param _lendingController Lending controller contract address.
     * @param _interestRateModel Token interest rate model contract address.
     * @param _msdController MSD controller contract address.
     * @param _collateral The iToken to be used as collateral.
     * @param _originationFeeRecipient MSD token fee recipient address.
     * @param _originationFeeRatio MSD token fee ratio.
     */
    function initialize(
        address _underlyingToken,
        string memory _name,
        string memory _symbol,
        IControllerInterface _lendingController,
        IInterestRateModelInterface _interestRateModel,
        MSDController _msdController,
        iToken _collateral,
        address _originationFeeRecipient,
        uint256 _originationFeeRatio
    ) external initializer {
        require(
            address(_underlyingToken) != address(0),
            "initialize: underlying address should not be zero address!"
        );
        require(
            address(_lendingController) != address(0),
            "initialize: controller address should not be zero address!"
        );
        require(
            address(_msdController) != address(0),
            "initialize: MSD controller address should not be zero address!"
        );
        require(
            address(_interestRateModel) != address(0),
            "initialize: interest model address should not be zero address!"
        );
        require(
            _collateral.isiToken(),
            "initialize: collateral should be an iToken!"
        );

        _initialize(
            _name,
            _symbol,
            ERC20(_underlyingToken).decimals(),
            _lendingController,
            _interestRateModel
        );

        underlying = IERC20Upgradeable(_underlyingToken);
        msdController = _msdController;

        reserveRatio = BASE;

        collateral = _collateral;
        collateralUnderlying = _collateral.underlying();
        collateralUnderlying.safeApprove(address(_collateral), uint256(-1));

        _setOriginationFeeRecipientInternal(_originationFeeRecipient);
        _setOriginationFeeRatioInternal(_originationFeeRatio);
    }

    function _setOriginationFeeRecipientInternal(
        address _newOriginationFeeRecipient
    ) internal {
        require(
            address(_newOriginationFeeRecipient) != address(0),
            "Fee recipent address should not be zero address!"
        );

        address _oldOriginationFeeRecipient = originationFeeRecipient;

        originationFeeRecipient = _newOriginationFeeRecipient;

        emit NewOriginationFeeRecipient(
            _oldOriginationFeeRecipient,
            _newOriginationFeeRecipient
        );
    }

    /**
     * @dev Sets a new Fee recipient.
     * @param _newOriginationFeeRecipient The new Fee recipient
     */
    function _setOriginationFeeRecipient(address _newOriginationFeeRecipient)
        external
        onlyOwner
    {
        _setOriginationFeeRecipientInternal(_newOriginationFeeRecipient);
    }

    function _setOriginationFeeRatioInternal(uint256 _newOriginationFeeRatio)
        internal
    {
        require(
            _newOriginationFeeRatio <= MAX_FEE_RATIO,
            "New fee ratio too large!"
        );

        uint256 _oldOriginationFeeRatio = originationFeeRatio;

        originationFeeRatio = _newOriginationFeeRatio;

        emit NewOriginationFeeRatio(
            _oldOriginationFeeRatio,
            _newOriginationFeeRatio
        );
    }

    /**
     * @dev Sets a new Fee ratio.
     * @param _newOriginationFeeRatio The new Fee ratio
     */
    function _setOriginationFeeRatio(uint256 _newOriginationFeeRatio)
        external
        onlyOwner
    {
        _setOriginationFeeRatioInternal(_newOriginationFeeRatio);
    }

    /**
     * @dev Caller borrows assets from the protocol.
     * @param _borrower The account that will borrow tokens.
     * @param _borrowAmount The amount of the underlying asset to borrow.
     */
    function _borrowInternal(address payable _borrower, uint256 _borrowAmount)
        internal
        override
    {
        controller.beforeBorrow(address(this), _borrower, _borrowAmount);

        // Calculates the new borrower and total borrow balances:
        //  newAccountBorrows = accountBorrows + borrowAmount
        //  newTotalBorrows = totalBorrows + borrowAmount
        BorrowSnapshot storage borrowSnapshot = accountBorrows[_borrower];
        borrowSnapshot.principal = _borrowBalanceInternal(_borrower).add(
            _borrowAmount
        );
        borrowSnapshot.interestIndex = borrowIndex;
        totalBorrows = totalBorrows.add(_borrowAmount);

        // Transfers token to borrower and fee recipient.
        uint256 fee = _borrowAmount.rmul(originationFeeRatio);

        _doTransferOut(_borrower, _borrowAmount.sub(fee));

        _doTransferOut(payable(originationFeeRecipient), fee);

        controller.afterBorrow(address(this), _borrower, _borrowAmount);

        emit Borrow(
            _borrower,
            _borrowAmount,
            borrowSnapshot.principal,
            borrowSnapshot.interestIndex,
            totalBorrows
        );
    }

    function depositAndBorrow(
        bool _enterMarket,
        uint256 _depositAmount,
        uint256 _borrowAmount
    ) external nonReentrant {
        if (_enterMarket) {
            controller.enterMarketFromiToken(address(collateral), msg.sender);
        }

        if (_depositAmount > 0) {
            collateralUnderlying.safeTransferFrom(
                msg.sender,
                address(this),
                _depositAmount
            );

            collateral.mint(msg.sender, _depositAmount);
        }

        if (_borrowAmount > 0) {
            _updateInterest();
            _borrowInternal(msg.sender, _borrowAmount);
        }
    }

    function repayAndWithdraw(
        bool _isUnderlying,
        uint256 _repayAmount,
        uint256 _withdrawAmount
    ) external nonReentrant {
        if (_repayAmount > 0) {
            _updateInterest();
            _repayInternal(msg.sender, msg.sender, _repayAmount);
        }

        if (_withdrawAmount > 0) {
            uint256 _before = collateralUnderlying.balanceOf(address(this));

            if (_isUnderlying) {
                collateral.redeemUnderlying(msg.sender, _withdrawAmount);
            } else {
                collateral.redeem(msg.sender, _withdrawAmount);
            }

            uint256 _after = collateralUnderlying.balanceOf(address(this));

            collateralUnderlying.safeTransfer(msg.sender, _after.sub(_before));
        }
    }
}
