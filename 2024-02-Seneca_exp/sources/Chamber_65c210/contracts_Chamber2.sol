// SPDX-License-Identifier: MIT
// Chamber
pragma solidity >=0.8.0;

import "@openzeppelin/contracts/access/Ownable2Step.sol";
import "@openzeppelin/contracts/security/Pausable.sol";
import "../contracts/interfaces/IMasterContract.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "../contracts/libraries/BoringRebase.sol";
import "@openzeppelin/contracts/utils/math/SafeMath.sol";
import "@openzeppelin/contracts/utils/math/SafeCast.sol";
import "../contracts/interfaces/IOracle.sol";
import "../contracts/interfaces/ISwapperV2.sol";
import "../contracts/interfaces/IBentoBoxV1.sol";
import "./Constants.sol";

contract Chamber is Ownable2Step, IMasterContract, Pausable {
    using SafeMath for uint256;
    using SafeMath for uint128;
    using SafeCast for uint256;
    using SafeCast for uint128;
    using RebaseLibrary for Rebase;
    using SafeERC20 for IERC20;

    event PriceUpdateEvent(uint256 rate);
    event AccumulateInterestEvent(uint128 accruedAmount);
    event DepositCollateralEvent(address indexed from, address indexed to, uint256 share);
    event WithdrawCollateralEvent(address indexed from, address indexed to, uint256 share);
    event BorrowEvent(address indexed from, address indexed to, uint256 amount, uint256 part);
    event RepayEvent(address indexed from, address indexed to, uint256 amount, uint256 part);
    event FeeToEvent(address indexed newFeeTo);
    event WithdrawFeesEvent(address indexed feeTo, uint256 feesEarnedFraction);
    event InterestChangeEvent(uint64 oldInterestRate, uint64 newInterestRate);
    event ChangeBlacklistedEvent(address indexed account, bool blacklisted);
    event LogChangeBorrowLimit(uint128 newLimit, uint128 perAddressPart);

    event LogLiquidation(
        address indexed from,
        address indexed user,
        address indexed to,
        uint256 collateralShare,
        uint256 borrowAmount,
        uint256 borrowPart
    );

    // Immutables (for MasterContract and all clones)
    IBentoBoxV1 public immutable bentoBox;
    Chamber public immutable masterContract;
    IERC20 public immutable senUSD;

    // MasterContract variables
    address public feeTo;

    // Per clone variables
    // Clone init settings
    IERC20 public collateral;
    IOracle public oracle;
    bytes public oracleData;

    uint256 public COLLATERIZATION_RATE;
    uint256 public LIQUIDATION_MULTIPLIER; 
    uint256 public BORROW_OPENING_FEE;

    struct BorrowCap {
        uint128 total;
        uint128 borrowPartPerAddress;
    }

    BorrowCap public borrowLimit;

    // Total amounts
    uint256 public totalCollateralShare; // Total collateral supplied
    Rebase public totalBorrow; // elastic = Total token amount to be repayed by borrowers, base = Total parts of the debt held by borrowers

    // User balances
    mapping(address => uint256) public userCollateralShare;
    mapping(address => uint256) public userBorrowPart;

    // Caller restrictions
    mapping(address => bool) public blacklisted;
    
    /// @notice Exchange and interest rate tracking.
    /// This is 'cached' here because calls to Oracles can be very expensive.
    uint256 public exchangeRate;

    struct AccruedInfo {
        uint64 lastAccrued;
        uint128 feesEarned;
        uint64 INTEREST_PER_SECOND;
    }

    AccruedInfo public accruedInterest;

    /// @notice tracks last interest rate
    uint256 internal lastInterestUpdate;

    modifier onlyMasterContractOwner() {
        require(msg.sender == masterContract.owner(), "Caller is not the owner");
        _;
    }

    /// @notice The constructor is only used for the initial master contract. Subsequent clones are initialised via `init`.
    constructor(IBentoBoxV1 bentoBox_, IERC20 senUSD_) {
        bentoBox = bentoBox_;
        senUSD = senUSD_;
        masterContract = this;
        
        blacklisted[address(bentoBox)] = true;
        blacklisted[address(this)] = true;
        blacklisted[Ownable(address(bentoBox)).owner()] = true;
    }

    /// @notice Serves as the constructor for clones, as clones can't have a regular constructor
    /// @dev `data` is abi encoded in the format: (IERC20 collateral, IERC20 asset, IOracle oracle, bytes oracleData)
    function init(bytes calldata data) public virtual payable override {
        require(address(collateral) == address(0), "Chamber: already initialized");
        (collateral, oracle, oracleData, accruedInterest.INTEREST_PER_SECOND, LIQUIDATION_MULTIPLIER, COLLATERIZATION_RATE, BORROW_OPENING_FEE) = abi.decode(data, (IERC20, IOracle, bytes, uint64, uint256, uint256, uint256));
        borrowLimit = BorrowCap(type(uint128).max, type(uint128).max);
        require(address(collateral) != address(0), "Chamber: bad pair");

        blacklisted[address(bentoBox)] = true;
        blacklisted[address(this)] = true;
        blacklisted[Ownable(address(bentoBox)).owner()] = true;

        (, exchangeRate) = oracle.get(oracleData);

        accumulate();
    }

    /// @notice Accrues the interest on the borrowed tokens and handles the accumulation of fees.
    function accumulate() whenNotPaused public {
        AccruedInfo memory _accruedInterest = accruedInterest;
        // Number of seconds since accrue was called
        uint256 elapsedTime = block.timestamp - _accruedInterest.lastAccrued;
        if (elapsedTime == 0) {
            return;
        }
        _accruedInterest.lastAccrued = uint64(block.timestamp);

        Rebase memory _totalBorrow = totalBorrow;
        if (_totalBorrow.base == 0) {
            accruedInterest = _accruedInterest;
            return;
        }


        uint128 extraAmount = uint128(uint256(_totalBorrow.elastic).mul(_accruedInterest.INTEREST_PER_SECOND).mul(elapsedTime) / 1e18);
        _totalBorrow.elastic = uint128(_totalBorrow.elastic.add(extraAmount));

        _accruedInterest.feesEarned = uint128(_accruedInterest.feesEarned.add(extraAmount));
        totalBorrow = _totalBorrow;
        accruedInterest = _accruedInterest;

        emit AccumulateInterestEvent(extraAmount);
    }

    /// @notice Concrete implementation of `isSolvent`. Includes a third parameter to allow caching `exchangeRate`.
    /// @param _exchangeRate The exchange rate. Used to cache the `exchangeRate` between calls.
    function _isSolvent(address user, uint256 _exchangeRate) virtual internal view returns (bool) {
        // accrue must have already been called!
        uint256 borrowPart = userBorrowPart[user];
        if (borrowPart == 0) return true;
        uint256 collateralShare = userCollateralShare[user];
        if (collateralShare == 0) return false;

        Rebase memory _totalBorrow = totalBorrow;

        return
            bentoBox.toAmount(
                collateral,
                collateralShare.mul(Constants.EXCHANGE_RATE_PRECISION / Constants.COLLATERIZATION_RATE_PRECISION).mul(COLLATERIZATION_RATE),
                false
            ) >=
            // Moved exchangeRate here instead of dividing the other side to preserve more precision
            borrowPart.mul(_totalBorrow.elastic).mul(_exchangeRate) / _totalBorrow.base;
    }

    function isSolvent(address user) public view returns (bool) {
        return _isSolvent(user, exchangeRate);
    }
    
    /// @dev Checks if the user is solvent in the closed liquidation case at the end of the function body.
    modifier solvent() {
        _;
        (, uint256 _exchangeRate) = updatePrice();
        require(_isSolvent(msg.sender, _exchangeRate), "Chamber: user insolvent");
    }

    /// @notice Gets the exchange rate. I.e how much collateral to buy 1e18 asset.
    /// This function is supposed to be invoked if needed because Oracle queries can be expensive.
    /// @return updated True if `exchangeRate` was updated.
    /// @return rate The new exchange rate.
    function updatePrice() public returns (bool updated, uint256 rate) {
        (updated, rate) = oracle.get(oracleData);

        if (updated) {
            exchangeRate = rate;
            emit PriceUpdateEvent(rate);
        } else {
            // Return the old rate if fetching wasn't successful
            rate = exchangeRate;
        }
    }

    /// @dev Helper function to move tokens.
    /// @param token The ERC-20 token.
    /// @param share The amount in shares to add.
    /// @param total Grand total amount to deduct from this contract's balance. Only applicable if `skim` is True.
    /// Only used for accounting checks.
    /// @param skim If True, only does a balance check on this contract.
    /// False if tokens from msg.sender in `bentoBox` should be transferred.
    function _addTokens(
        IERC20 token,
        uint256 share,
        uint256 total,
        bool skim
    ) internal {
        if (skim) {
            require(share <= bentoBox.balanceOf(token, address(this)).sub(total), "Chamber: Skim too much");
        } else {
            bentoBox.transfer(token, msg.sender, address(this), share);
        }
    }

    function _afterAddCollateral(address user, uint256 collateralShare) internal virtual {}

    /// @notice Adds `collateral` from msg.sender to the account `to`.
    /// @param to The receiver of the tokens.
    /// @param skim True if the amount should be skimmed from the deposit balance of msg.sender.x
    /// False if tokens from msg.sender in `bentoBox` should be transferred.
    /// @param share The amount of shares to add for `to`.
    function depositCollateral(
        address to,
        bool skim,
        uint256 share
    ) whenNotPaused public virtual {
        userCollateralShare[to] = userCollateralShare[to].add(share);
        uint256 oldTotalCollateralShare = totalCollateralShare;
        totalCollateralShare = oldTotalCollateralShare.add(share);
        _addTokens(collateral, share, oldTotalCollateralShare, skim);
        _afterAddCollateral(to, share);
        emit DepositCollateralEvent(skim ? address(bentoBox) : msg.sender, to, share);
    }

    function _afterWithdrawnCollateral(address from, address to, uint256 collateralShare) internal virtual {}

    /// @dev Concrete implementation of `withdrawCollateral`.
    function _withdrawCollateral(address to, uint256 share) whenNotPaused internal virtual {
        userCollateralShare[msg.sender] = userCollateralShare[msg.sender].sub(share);
        totalCollateralShare = totalCollateralShare.sub(share);
        _afterWithdrawnCollateral(msg.sender, to, share);
        emit WithdrawCollateralEvent(msg.sender, to, share);
        bentoBox.transfer(collateral, address(this), to, share);
    }

    /// @notice Removes `share` amount of collateral and transfers it to `to`.
    /// @param to The receiver of the shares.
    /// @param share Amount of shares to remove.
    function removeCollateral(address to, uint256 share) whenNotPaused public solvent {
        // accrue must be called because we check solvency
        accumulate();
        _withdrawCollateral(to, share);
    }

    function _preBorrowAction(address to, uint256 amount, uint256 newBorrowPart, uint256 part) internal virtual {

    }

    /// @dev Concrete implementation of `borrow`.
    function _borrow(address to, uint256 amount) whenNotPaused internal returns (uint256 part, uint256 share) {
        uint256 feeAmount = amount.mul(BORROW_OPENING_FEE) / Constants.BORROW_OPENING_FEE_PRECISION; // A flat % fee is charged for any borrow
        (totalBorrow, part) = totalBorrow.add(amount.add(feeAmount), true);
        senUSD.safeApprove(address(bentoBox), amount);
        BorrowCap memory cap =  borrowLimit;

        require(totalBorrow.elastic <= cap.total, "Borrow Limit reached");

        accruedInterest.feesEarned = uint128(accruedInterest.feesEarned.add(uint128(feeAmount)));
        
        uint256 newBorrowPart = userBorrowPart[msg.sender].add(part);
        require(newBorrowPart <= cap.borrowPartPerAddress, "Borrow Limit reached");
        _preBorrowAction(to, amount, newBorrowPart, part);

        userBorrowPart[msg.sender] = newBorrowPart;

        // As long as there are tokens on this contract you can 'mint'... this enables limiting borrows
        share = bentoBox.toShare(senUSD, amount, false);
        bentoBox.transfer(senUSD, address(this), to, share);
        senUSD.approve(address(bentoBox), 0);
        emit BorrowEvent(msg.sender, to, amount.add(feeAmount), part);
    }

    /// @notice Sender borrows `amount` and transfers it to `to`.
    /// @return part Total part of the debt held by borrowers.
    /// @return share Total amount in shares borrowed.
    function borrow(address to, uint256 amount) whenNotPaused public solvent returns (uint256 part, uint256 share) {
        accumulate();
        (part, share) = _borrow(to, amount);
    }

    /// @dev Concrete implementation of `repay`.
    function _repay(
        address to,
        bool skim,
        uint256 part
    ) whenNotPaused internal returns (uint256 amount) {
        (totalBorrow, amount) = totalBorrow.sub(part, true);
        userBorrowPart[to] = userBorrowPart[to].sub(part);

        uint256 share = bentoBox.toShare(senUSD, amount, true);
        senUSD.safeApprove(address(bentoBox), amount);

        bentoBox.transfer(senUSD, skim ? address(bentoBox) : msg.sender, address(this), share);
        senUSD.approve(address(bentoBox), 0);
        emit RepayEvent(skim ? address(bentoBox) : msg.sender, to, amount, part);
    }

    /// @notice Repays a loan.
    /// @param to Address of the user this payment should go.
    /// @param skim True if the amount should be skimmed from the deposit balance of msg.sender.
    /// False if tokens from msg.sender in `bentoBox` should be transferred.
    /// @param part The amount to repay. See `userBorrowPart`.
    /// @return amount The total amount repayed.
    function repay(
        address to,
        bool skim,
        uint256 part
    ) whenNotPaused public returns (uint256 amount) {
        accumulate();
        amount = _repay(to, skim, part);
    }

    /// @dev Helper function for choosing the correct value (`value1` or `value2`) depending on `inNum`.
    function _num(
        int256 inNum,
        uint256 value1,
        uint256 value2
    ) internal pure returns (uint256 outNum) {
        outNum = inNum >= 0 ? uint256(inNum) : (inNum == Constants.USE_PARAM1 ? value1 : value2);
    }

    /// @dev Helper function for depositing into `bentoBox`.
    function _bentoDeposit(
        bytes memory data,
        uint256 value,
        uint256 value1,
        uint256 value2
    ) whenNotPaused internal returns (uint256, uint256) {
        (IERC20 token, address to, int256 amount, int256 share) = abi.decode(data, (IERC20, address, int256, int256));
        amount = int256(_num(amount, value1, value2)); // Done this way to avoid stack too deep errors
        share = int256(_num(share, value1, value2));

        return bentoBox.deposit{value: value}(token, msg.sender, to, uint256(amount), uint256(share));
    }

    /// @dev Helper function to withdraw from the `bentoBox`.
    function _bentoWithdraw(
        bytes memory data,
        uint256 value1,
        uint256 value2
    ) whenNotPaused internal returns (uint256, uint256) {
        (IERC20 token, address to, int256 amount, int256 share) = abi.decode(data, (IERC20, address, int256, int256));

        return bentoBox.withdraw(token, msg.sender, to, _num(amount, value1, value2), _num(share, value1, value2));
    }

    /// @dev Helper function to perform a contract call and eventually extracting revert messages on failure.
    /// Calls to `bentoBox` are not allowed for obvious security reasons.
    /// This also means that calls made from this contract shall *not* be trusted.
    function _call(
        uint256 value,
        bytes memory data,
        uint256 value1,
        uint256 value2
    ) whenNotPaused internal returns (bytes memory, uint8) {
        (address callee, bytes memory callData, bool useValue1, bool useValue2, uint8 returnValues) =
            abi.decode(data, (address, bytes, bool, bool, uint8));

        if (useValue1 && !useValue2) {
            callData = abi.encodePacked(callData, value1);
        } else if (!useValue1 && useValue2) {
            callData = abi.encodePacked(callData, value2);
        } else if (useValue1 && useValue2) {
            callData = abi.encodePacked(callData, value1, value2);
        }

        require(!blacklisted[callee], "Chamber: can't call");

        (bool success, bytes memory returnData) = callee.call{value: value}(callData);
        require(success, "Chamber: call failed");
        return (returnData, returnValues);
    }

    struct OperationStatus {
        bool needsSolvencyCheck;
        bool hasAccrued;
    }

    function _extraOperation(uint8 action, OperationStatus memory, uint256 value, bytes memory data, uint256 value1, uint256 value2) internal virtual returns (bytes memory, uint8, OperationStatus memory) {}

    /// @notice Executes a set of actions and allows composability (contract calls) to other contracts.
    /// @param actions An array with a sequence of actions to execute (see OPERATION_ declarations).
    /// @param values A one-to-one mapped array to `actions`. ETH amounts to send along with the actions.
    /// Only applicable to `OPERATION`, `OPERATION_BENTO_DEPOSIT`.
    /// @param datas A one-to-one mapped array to `operations`. Contains abi encoded data of function arguments.
    /// @return value1 May contain the first positioned return value of the last executed action (if applicable).
    /// @return value2 May contain the second positioned return value of the last executed action which returns 2 values (if applicable).
    function performOperations(
        uint8[] calldata actions,
        uint256[] calldata values,
        bytes[] calldata datas
    ) whenNotPaused external payable returns (uint256 value1, uint256 value2) {
        OperationStatus memory status;
        uint256 actionsLength = actions.length;
        for (uint256 i = 0; i < actionsLength; i++) {
            uint8 action = actions[i];
            if (!status.hasAccrued && action < 10) {
                accumulate();
                status.hasAccrued = true;
            }
            if (action == Constants.OPERATION_ADD_COLLATERAL) {
                (int256 share, address to, bool skim) = abi.decode(datas[i], (int256, address, bool));
                depositCollateral(to, skim, _num(share, value1, value2));
            } else if (action == Constants.OPERATION_REPAY) {
                (int256 part, address to, bool skim) = abi.decode(datas[i], (int256, address, bool));
                _repay(to, skim, _num(part, value1, value2));
            } else if (action == Constants.OPERATION_REMOVE_COLLATERAL) {
                (int256 share, address to) = abi.decode(datas[i], (int256, address));
                _withdrawCollateral(to, _num(share, value1, value2));
                status.needsSolvencyCheck = true;
            } else if (action == Constants.OPERATION_BORROW) {
                (int256 amount, address to) = abi.decode(datas[i], (int256, address));
                (value1, value2) = _borrow(to, _num(amount, value1, value2));
                status.needsSolvencyCheck = true;
            } else if (action == Constants.OPERATION_UPDATE_PRICE) {
                (bool must_update, uint256 minRate, uint256 maxRate) = abi.decode(datas[i], (bool, uint256, uint256));
                (bool updated, uint256 rate) = updatePrice();
                require((!must_update || updated) && rate > minRate && (maxRate == 0 || rate < maxRate), "Chamber: rate not ok");
            } else if (action == Constants.OPERATION_BENTO_SETAPPROVAL) {
                (address user, address _masterContract, bool approved, uint8 v, bytes32 r, bytes32 s) =
                    abi.decode(datas[i], (address, address, bool, uint8, bytes32, bytes32));
                bentoBox.setMasterContractApproval(user, _masterContract, approved, v, r, s);
            } else if (action == Constants.OPERATION_BENTO_DEPOSIT) {
                (value1, value2) = _bentoDeposit(datas[i], values[i], value1, value2);
            } else if (action == Constants.OPERATION_BENTO_WITHDRAW) {
                (value1, value2) = _bentoWithdraw(datas[i], value1, value2);
            } else if (action == Constants.OPERATION_BENTO_TRANSFER) {
                (IERC20 token, address to, int256 share) = abi.decode(datas[i], (IERC20, address, int256));
                bentoBox.transfer(token, msg.sender, to, _num(share, value1, value2));
            } else if (action == Constants.OPERATION_BENTO_TRANSFER_MULTIPLE) {
                (IERC20 token, address[] memory tos, uint256[] memory shares) = abi.decode(datas[i], (IERC20, address[], uint256[]));
                bentoBox.transferMultiple(token, msg.sender, tos, shares);
            } else if (action == Constants.OPERATION_CALL) {
                (bytes memory returnData, uint8 returnValues) = _call(values[i], datas[i], value1, value2);

                if (returnValues == 1) {
                    (value1) = abi.decode(returnData, (uint256));
                } else if (returnValues == 2) {
                    (value1, value2) = abi.decode(returnData, (uint256, uint256));
                }
            } else if (action == Constants.OPERATION_GET_REPAY_SHARE) {
                int256 part = abi.decode(datas[i], (int256));
                value1 = bentoBox.toShare(senUSD, totalBorrow.toElastic(_num(part, value1, value2), true), true);
            } else if (action == Constants.OPERATION_GET_REPAY_PART) {
                int256 amount = abi.decode(datas[i], (int256));
                value1 = totalBorrow.toBase(_num(amount, value1, value2), false);
            } else if (action == Constants.OPERATION_LIQUIDATE) {
                _operationLiquidate(datas[i]);
            } else {
                (bytes memory returnData, uint8 returnValues, OperationStatus memory returnStatus) = _extraOperation(action, status, values[i], datas[i], value1, value2);
                status = returnStatus;
                
                if (returnValues == 1) {
                    (value1) = abi.decode(returnData, (uint256));
                } else if (returnValues == 2) {
                    (value1, value2) = abi.decode(returnData, (uint256, uint256));
                }
            }
        }

        if (status.needsSolvencyCheck) {
            (, uint256 _exchangeRate) = updatePrice();
            require(_isSolvent(msg.sender, _exchangeRate), "Chamber: user insolvent");
        }
    }

    function _operationLiquidate(bytes calldata data) internal {
        (address[] memory users, uint256[] memory maxBorrowParts, address to, ISwapperV2 swapper, bytes memory swapperData) = abi.decode(data, (address[], uint256[], address, ISwapperV2, bytes));
        liquidate(users, maxBorrowParts, to, swapper, swapperData);
    }

    function _beforeUsersLiquidated(address[] memory users, uint256[] memory maxBorrowPart) internal virtual {}

    function _beforeUserLiquidated(address user, uint256 borrowPart, uint256 borrowAmount, uint256 collateralShare) internal virtual {}

    function _afterUserLiquidated(address user, uint256 collateralShare) internal virtual {}

    /// @notice Handles the liquidation of users' balances, once the users' amount of collateral is too low.
    /// @param users An array of user addresses.
    /// @param maxBorrowParts A one-to-one mapping to `users`, contains maximum (partial) borrow amounts (to liquidate) of the respective user.
    /// @param to Address of the receiver in open liquidations if `swapper` is zero.
    function liquidate(
        address[] memory users,
        uint256[] memory maxBorrowParts,
        address to,
        ISwapperV2 swapper,
        bytes memory swapperData
    ) whenNotPaused public virtual {
        // Oracle can fail but we still need to allow liquidations
        (, uint256 _exchangeRate) = updatePrice();
        accumulate();

        uint256 allCollateralShare;
        uint256 allBorrowAmount;
        uint256 allBorrowPart;
        Rebase memory bentoBoxTotals = bentoBox.totals(collateral);
        _beforeUsersLiquidated(users, maxBorrowParts);
        uint256 usersLength = users.length;
        for (uint256 i = 0; i < usersLength; i++) {
            address user = users[i];
            if (!_isSolvent(user, _exchangeRate)) {
                uint256 borrowPart;
                uint256 availableBorrowPart = userBorrowPart[user];
                borrowPart = maxBorrowParts[i] > availableBorrowPart ? availableBorrowPart : maxBorrowParts[i];

                uint256 borrowAmount = totalBorrow.toElastic(borrowPart, false);
                uint256 collateralShare =
                    bentoBoxTotals.toBase(
                        borrowAmount.mul(LIQUIDATION_MULTIPLIER).mul(_exchangeRate) /
                            (Constants.LIQUIDATION_MULTIPLIER_PRECISION * Constants.EXCHANGE_RATE_PRECISION),
                        false
                    );

                _beforeUserLiquidated(user, borrowPart, borrowAmount, collateralShare);
                userBorrowPart[user] = availableBorrowPart.sub(borrowPart);
                userCollateralShare[user] = userCollateralShare[user].sub(collateralShare);
                _afterUserLiquidated(user, collateralShare);

                emit WithdrawCollateralEvent(user, to, collateralShare);
                emit RepayEvent(msg.sender, user, borrowAmount, borrowPart);
                emit LogLiquidation(msg.sender, user, to, collateralShare, borrowAmount, borrowPart);

                // Keep totals
                allCollateralShare = allCollateralShare.add(collateralShare);
                allBorrowAmount = allBorrowAmount.add(borrowAmount);
                allBorrowPart = allBorrowPart.add(borrowPart);
            }
        }
        require(allBorrowAmount != 0, "Chamber: all are solvent");
        totalBorrow.elastic = uint128(totalBorrow.elastic.sub(allBorrowAmount));
        totalBorrow.base = uint128(totalBorrow.base.sub(allBorrowPart));
        totalCollateralShare = totalCollateralShare.sub(allCollateralShare);

        {
            uint256 distributionAmount = (allBorrowAmount.mul(LIQUIDATION_MULTIPLIER) / Constants.LIQUIDATION_MULTIPLIER_PRECISION).sub(allBorrowAmount).mul(Constants.DISTRIBUTION_PART) / Constants.DISTRIBUTION_PRECISION; // Distribution Amount
            allBorrowAmount = allBorrowAmount.add(distributionAmount);
            accruedInterest.feesEarned = uint128(accruedInterest.feesEarned.add(distributionAmount));
        }

        uint256 allBorrowShare = bentoBox.toShare(senUSD, allBorrowAmount, true);

        // Swap using a swapper freely chosen by the caller
        // Open (flash) liquidation: get proceeds first and provide the borrow after
        bentoBox.transfer(collateral, address(this), to, allCollateralShare);
        if (swapper != ISwapperV2(address(0))) {
            swapper.swap(address(collateral), address(senUSD), msg.sender, allBorrowShare, allCollateralShare, swapperData);
        }

        allBorrowShare = bentoBox.toShare(senUSD, allBorrowAmount, true);
        bentoBox.transfer(senUSD, msg.sender, address(this), allBorrowShare);
    }

    /// @notice Withdraws the fees accumulated.
    function withdrawFees() public {
        accumulate();
        address _feeTo = masterContract.feeTo();
        uint256 _feesEarned = accruedInterest.feesEarned;
        uint256 share = bentoBox.toShare(senUSD, _feesEarned, false);
        bentoBox.transfer(senUSD, address(this), _feeTo, share);
        accruedInterest.feesEarned = 0;

        emit WithdrawFeesEvent(_feeTo, _feesEarned);
    }

    /// @notice Sets the beneficiary of interest accrued.
    /// MasterContract Only Admin function.
    /// @param newFeeTo The address of the receiver.
    function setFeeTo(address newFeeTo) public onlyOwner {
        require(newFeeTo != address(0), 'cannot be 0 address');
        feeTo = newFeeTo;
        emit FeeToEvent(newFeeTo);
    }

    /// @notice reduces the supply of SENUSD
    /// @param amount amount to reduce supply by
    function reduceSupply(uint256 amount) public onlyMasterContractOwner {
        uint256 maxAmount = bentoBox.toAmount(senUSD, bentoBox.balanceOf(senUSD, address(this)), false);
        amount = maxAmount > amount ? amount : maxAmount;
        bentoBox.withdraw(senUSD, address(this), msg.sender, amount, 0);
    }

    /// @notice allows to change the interest rate
    /// @param newInterestRateBps new interest rate in basis points
    function changeInterestRate(uint16 newInterestRateBps) public onlyMasterContractOwner {
        uint64 oldInterestRate = accruedInterest.INTEREST_PER_SECOND;

        uint64 newInterestRate = fromBps(newInterestRateBps);
        
        require(newInterestRate < oldInterestRate + oldInterestRate * 3 / 4 || newInterestRate <= ONE_PERCENT_RATE(), "Interest rate increase > 75%");
        require(lastInterestUpdate + 3 days < block.timestamp, "Update only every 3 days");

        lastInterestUpdate = block.timestamp;
        accruedInterest.INTEREST_PER_SECOND = newInterestRate;
        emit InterestChangeEvent(oldInterestRate, newInterestRate);
    }

    /// @notice allows to change the borrow limit
    /// @param newBorrowLimit new borrow limit
    /// @param perAddressPart new borrow limit per address
    function changeBorrowLimit(uint128 newBorrowLimit, uint128 perAddressPart) public onlyMasterContractOwner {
        borrowLimit = BorrowCap(newBorrowLimit, perAddressPart);
        emit LogChangeBorrowLimit(newBorrowLimit, perAddressPart);
    }

    /// @notice allows to change blacklisted callees
    /// @param callee callee to blacklist or not
    /// @param _blacklisted true when the callee cannot be used in call cook action
    function setBlacklistedCaller(address callee, bool _blacklisted) public onlyMasterContractOwner {
        require(callee != address(0), 'invalid callee');
        require(callee != address(bentoBox) && callee != address(this), "invalid callee");

        blacklisted[callee] = _blacklisted;
        emit ChangeBlacklistedEvent(callee, _blacklisted);
    }

    function fromBps(uint16 rate) internal pure returns (uint64) {
            return uint64(rate) * Constants.PERCENT_RATE / Constants.BASIS_POINTS_DENOM; 
    }

    function ONE_PERCENT_RATE() internal pure returns (uint64) {
            return Constants.PERCENT_RATE;
    }
}