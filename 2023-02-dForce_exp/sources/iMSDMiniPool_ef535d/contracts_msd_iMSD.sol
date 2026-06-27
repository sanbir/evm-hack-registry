// SPDX-License-Identifier: MIT
pragma solidity 0.6.12;

import "../TokenBase/Base.sol";
import "./MSDController.sol";
import "./MSD.sol";

/**
 * @title dForce's Lending Protocol Contract.
 * @notice dForce lending token for the Multi-currency Stable Debt Token.
 * @author dForce Team.
 */
contract iMSD is Base {
    MSDController public msdController;

    event NewMSDController(
        MSDController oldMSDController,
        MSDController newMSDController
    );

    /**
     * @notice Expects to call only once to initialize a new market.
     * @param _underlyingToken The underlying token address.
     * @param _name Token name.
     * @param _symbol Token symbol.
     * @param _lendingController Lending controller contract address.
     * @param _interestRateModel Token interest rate model contract address.
     * @param _msdController MSD controller contract address.
     */
    function initialize(
        address _underlyingToken,
        string memory _name,
        string memory _symbol,
        IControllerInterface _lendingController,
        IInterestRateModelInterface _interestRateModel,
        MSDController _msdController
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
    }

    /**
     * @dev Reserve ratio of iMSD is fixed to 100%.
     * All interests iMSD generated goes to reserve, this should be called when migrating
     */
    function _setNewReserveRatio(uint256 _newReserveRatio)
        external
        override
        onlyOwner
        settleInterest
    {
        // Gets current reserve ratio.
        uint256 _oldReserveRatio = reserveRatio;

        // Sets new reserve ratio.
        reserveRatio = BASE;

        emit NewReserveRatio(_oldReserveRatio, BASE);

        _newReserveRatio;
    }

    /**
     * @dev Admin withdraws `_withdrawAmount` of the reserve
     * skip the default check of cash as iMSD hold 0 cash.
     * @param _withdrawAmount Amount of reserves to withdraw.
     */
    function _withdrawReserves(uint256 _withdrawAmount)
        external
        override
        onlyOwner
        settleInterest
    {
        require(
            _withdrawAmount <= totalReserves,
            "_withdrawReserves: Invalid withdraw amount!"
        );

        uint256 _oldTotalReserves = totalReserves;
        // Updates total amount of the reserves.
        totalReserves = totalReserves.sub(_withdrawAmount);

        // Transfers reserve to the owner.
        _doTransferOut(owner, _withdrawAmount);

        emit ReservesWithdrawn(
            owner,
            _withdrawAmount,
            totalReserves,
            _oldTotalReserves
        );
    }

    /**
     * @dev Sets a new MSD controller.
     * @param _newMSDController The new MSD controller
     */
    function _setMSDController(MSDController _newMSDController)
        external
        onlyOwner
    {
        MSDController _oldMSDController = msdController;

        // Ensures the input address is a MSDController contract.
        require(
            _newMSDController.isMSDController(),
            "_setMSDController: This is not MSD controller contract!"
        );

        msdController = _newMSDController;

        emit NewMSDController(_oldMSDController, _newMSDController);
    }

    /**
     * @notice Supposed to transfer underlying token into this contract
     * @dev iMSD burns the amount of underlying rather than transfering.
     */
    function _doTransferIn(address _sender, uint256 _amount)
        internal
        override
        returns (uint256)
    {
        MSD(address(underlying)).burn(_sender, _amount);
        return _amount;
    }

    /**
     * @notice Supposed to transfer underlying token to `_recipient`
     * @dev iMSD mint the amount of underlying rather than transfering.
     * this can be called by `borrow()` and `_withdrawReserves()`
     * Reserves should stay 0 for iMSD
     */
    function _doTransferOut(address payable _recipient, uint256 _amount)
        internal
        override
    {
        msdController.mintMSD(address(underlying), _recipient, _amount);
    }

    /**
     * @dev iMSD does not hold any underlying in cash, returning 0
     */
    function _getCurrentCash() internal view override returns (uint256) {
        return 0;
    }

    /**
     * @dev Caller borrows tokens from the protocol to their own address.
     * @param _borrowAmount The amount of the underlying token to borrow.
     */
    function borrow(uint256 _borrowAmount)
        external
        nonReentrant
        settleInterest
    {
        _borrowInternal(msg.sender, _borrowAmount);
    }

    /**
     * @dev Caller repays their own borrow.
     * @param _repayAmount The amount to repay.
     */
    function repayBorrow(uint256 _repayAmount)
        external
        nonReentrant
        settleInterest
    {
        _repayInternal(msg.sender, msg.sender, _repayAmount);
    }

    /**
     * @dev Caller repays a borrow belonging to borrower.
     * @param _borrower the account with the debt being payed off.
     * @param _repayAmount The amount to repay.
     */
    function repayBorrowBehalf(address _borrower, uint256 _repayAmount)
        external
        nonReentrant
        settleInterest
    {
        _repayInternal(msg.sender, _borrower, _repayAmount);
    }

    /**
     * @dev The caller liquidates the borrowers collateral.
     * @param _borrower The account whose borrow should be liquidated.
     * @param _assetCollateral The market in which to seize collateral from the borrower.
     * @param _repayAmount The amount to repay.
     */
    function liquidateBorrow(
        address _borrower,
        uint256 _repayAmount,
        address _assetCollateral
    ) external nonReentrant settleInterest {
        // Liquidate and seize the same token will call _seizeInternal() instead of seize()
        require(
            _assetCollateral != address(this),
            "iMSD Token can not be seized"
        );

        _liquidateBorrowInternal(_borrower, _repayAmount, _assetCollateral);
    }

    /**
     * @dev iMSD does not support seize(), but it is required by liquidateBorrow()
     * @param _liquidator The account receiving seized collateral.
     * @param _borrower The account having collateral seized.
     * @param _seizeTokens The number of iMSDs to seize.
     */
    function seize(
        address _liquidator,
        address _borrower,
        uint256 _seizeTokens
    ) external override {
        _liquidator;
        _borrower;
        _seizeTokens;

        revert("iMSD Token can not be seized");
    }

    /**
     * @notice Calculates interest and update total borrows and reserves.
     * @dev Updates total borrows and reserves with any accumulated interest.
     */
    function updateInterest() external override returns (bool) {
        _updateInterest();
        return true;
    }

    /**
     * @dev Gets the newest exchange rate by accruing interest.
     * iMSD returns the initial exchange rate 1.0
     */
    function exchangeRateCurrent() external pure returns (uint256) {
        return initialExchangeRate;
    }

    /**
     * @dev Calculates the exchange rate without accruing interest.
     * iMSD returns the initial exchange rate 1.0
     */
    function exchangeRateStored() external view override returns (uint256) {
        return initialExchangeRate;
    }

    /**
     * @dev Gets the underlying balance of the `_account`.
     * @param _account The address of the account to query.
     * iMSD just returns 0
     */
    function balanceOfUnderlying(address _account)
        external
        pure
        returns (uint256)
    {
        _account;
        return 0;
    }

    /**
     * @dev Gets the user's borrow balance with the latest `borrowIndex`.
     */
    function borrowBalanceCurrent(address _account)
        external
        nonReentrant
        returns (uint256)
    {
        // Accrues interest.
        _updateInterest();

        return _borrowBalanceInternal(_account);
    }

    /**
     * @dev Gets the borrow balance of user without accruing interest.
     */
    function borrowBalanceStored(address _account)
        external
        view
        override
        returns (uint256)
    {
        return _borrowBalanceInternal(_account);
    }

    /**
     * @dev Gets user borrowing information.
     */
    function borrowSnapshot(address _account)
        external
        view
        returns (uint256, uint256)
    {
        return (
            accountBorrows[_account].principal,
            accountBorrows[_account].interestIndex
        );
    }

    /**
     * @dev Gets the current total borrows by accruing interest.
     */
    function totalBorrowsCurrent() external returns (uint256) {
        // Accrues interest.
        _updateInterest();

        return totalBorrows;
    }

    /**
     * @dev Returns the current per-block borrow interest rate.
     * iMSD uses fixed interest rate model
     */
    function borrowRatePerBlock() public view returns (uint256) {
        return
            interestRateModel.getBorrowRate(
                _getCurrentCash(),
                totalBorrows,
                totalReserves
            );
    }

    /**
     * @dev Get cash balance of this iToken in the underlying token.
     */
    function getCash() external view returns (uint256) {
        return _getCurrentCash();
    }

    /**
     * @notice Check whether is a iToken contract, return false for iMSD contract.
     */
    function isiToken() external pure override returns (bool) {
        return false;
    }

    /**
     * @notice The total mint of the underlying MSD token, queried by MSD controller.
     */
    function totalMint() external view returns (uint256) {
        return totalBorrows;
    }
}
