/*
        [....     [... [......  [.. ..
      [..    [..       [..    [..    [..
    [..        [..     [..     [..         [..       [..
    [..        [..     [..       [..     [.   [..  [..  [..
    [..        [..     [..          [.. [..... [..[..   [..
      [..     [..      [..    [..    [..[.        [..   [..
        [....          [..      [.. ..    [....     [.. [...

    OTSea Staking.

    https://otsea.io
    https://t.me/OTSeaPortal
    https://twitter.com/OTSeaERC20
*/

// SPDX-License-Identifier: MIT
pragma solidity =0.8.20;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@uniswap/v2-periphery/contracts/interfaces/IUniswapV2Router02.sol";
import "contracts/helpers/ListHelper.sol";
import "contracts/helpers/TransferHelper.sol";
import "contracts/libraries/OTSeaErrors.sol";

/**
 * @title OTSea Staking Contract
 * @dev This contract enables users to stake tokens and earn rewards from v1 token fees and platform revenue.
 * It initiates a new epoch with each reward distribution. Users who stake during an epoch do not receive rewards
 * for that epoch, preventing exploitation through immediate pre-reward staking and withdrawal.
 * Similarly, users withdrawing their stake in any epoch forfeit rewards that would be distributed at the end of
 * the epoch. Rewards are calculated pro-rata based on the token amount staked in each epoch.
 *
 * If the revenue for distribution is less than 0.0001 ETH or if the total staked tokens are fewer than 1, the current
 * epoch is skipped. No rewards are distributed in this case, and the accumulated revenue is carried over to the
 * next epoch.
 */
contract OTSeaStaking is Ownable, TransferHelper, ListHelper {
    using SafeERC20 for IERC20;

    struct Deposit {
        /**
         * @dev rewardReferenceEpoch represents the reference point that rewards should be based off of.
         *  - Upon depositing it is set to the currentEpoch + 1.
         *  - Upon claiming rewards it is set to the currentEpoch
         *  - Upon withdrawing it is set to 0
         */
        uint32 rewardReferenceEpoch;
        uint88 amount;
    }

    struct Epoch {
        uint168 startedAt;
        uint88 totalStake;
        uint256 sharePerToken;
    }

    IUniswapV2Router02 private constant _router =
        IUniswapV2Router02(0x7a250d5630B4cF539739dF2C5dAcb4c659F2488D);
    uint256 private constant REWARD_PRECISION = 10e38;
    address private immutable _revenueDistributor;
    bool public isDepositingAllowed;
    uint32 private _currentEpoch = 1;
    IERC20 private _otseaERC20;
    mapping(address => Deposit[]) private _deposits;
    mapping(uint32 => Epoch) private _epochs;

    error NoRewards();
    error InvalidEpoch();
    error DepositNotFound(uint256 index);

    event Initialized(address token);
    event ToggledDepositing(bool isDepositingAllowed);
    event Deposited(address indexed account, uint256 indexed index, Deposit deposit);
    event Withdrawal(
        address indexed account,
        address indexed receiver,
        uint256[] indexes,
        uint88 amount
    );
    event Claimed(
        address indexed account,
        address indexed receiver,
        uint256[] indexes,
        uint256 amount
    );
    event Compounded(
        address indexed account,
        uint256[] indexes,
        uint256 amountSwapped,
        uint256 indexed newDepositIndex,
        Deposit deposit
    );
    event EpochEnded(uint32 indexed id, Epoch epoch, uint256 distributed);

    modifier onlyRevenueDistributor() {
        _isCallerRevenueDistributor();
        _;
    }

    /**
     * @param _multiSigAdmin Multi-sig admin
     * @param revenueDistributor_ Revenue distributor contract
     */
    constructor(address _multiSigAdmin, address revenueDistributor_) Ownable(_multiSigAdmin) {
        if (address(revenueDistributor_) == address(0)) revert OTSeaErrors.InvalidAddress();
        _revenueDistributor = revenueDistributor_;
    }

    /**
     * @notice Initialize and start the first epoch
     * @param _token Token
     */
    function initialize(IERC20 _token) external onlyOwner {
        if (address(_token) == address(0)) revert OTSeaErrors.InvalidAddress();
        if (_isInitialized()) revert OTSeaErrors.NotAvailable();
        _otseaERC20 = _token;
        _epochs[1].startedAt = uint168(block.timestamp);
        emit Initialized(address(_token));
    }

    /// @notice Toggle depositing
    function toggleDepositing() external onlyOwner {
        if (!_isInitialized()) revert OTSeaErrors.NotAvailable();
        isDepositingAllowed = !isDepositingAllowed;
        emit ToggledDepositing(isDepositingAllowed);
    }

    /// @notice Distribute ETH to stakers (only revenue distributor)
    function distribute() external payable onlyRevenueDistributor {
        uint32 currentEpoch = _currentEpoch;
        uint256 sharePerToken = (REWARD_PRECISION * msg.value) / _epochs[currentEpoch].totalStake;
        _epochs[currentEpoch].sharePerToken += sharePerToken;
        _nextEpoch();
        emit EpochEnded(currentEpoch, _epochs[currentEpoch], msg.value);
    }

    /// @notice Skip epoch (only revenue distributor)
    function skipEpoch() external onlyRevenueDistributor {
        uint32 currentEpoch = _currentEpoch;
        _nextEpoch();
        emit EpochEnded(currentEpoch, _epochs[currentEpoch], 0);
    }

    /**
     * @notice Stake OTSea tokens and earn ETH
     * @param _amount OTSea amount
     */
    function stake(uint88 _amount) external {
        if (!isDepositingAllowed) revert OTSeaErrors.NotAvailable();
        if (_amount == 0) revert OTSeaErrors.InvalidAmount();
        _checkSufficientAmount(_amount);
        /**
         * @dev current deposit index = _deposits[_msgSender()].length - 1, therefore if we add 1 to get the next index
         * it cancels out with the "-1" to just give _deposits[_msgSender()].length
         */
        Deposit memory deposit = _createDeposit(_amount);
        _otseaERC20.safeTransferFrom(_msgSender(), address(this), uint256(_amount));
        emit Deposited(_msgSender(), _deposits[_msgSender()].length - 1, deposit);
    }

    /**
     * @notice Withdraw multiple deposits as well as claim their rewards
     * @param _indexes A list of deposit IDs to withdraw
     * @param _receiver Address to receive the tokens and ETH
     */
    function withdraw(uint256[] calldata _indexes, address _receiver) external {
        if (_receiver == address(0)) revert OTSeaErrors.InvalidAddress();
        (uint88 totalAmount, uint256 totalRewards) = _withdrawMultiple(_indexes);
        if (totalRewards != 0) {
            _transferETHOrRevert(_receiver, totalRewards);
            emit Claimed(_msgSender(), _receiver, _indexes, totalRewards);
        }
        _otseaERC20.safeTransfer(_receiver, uint256(totalAmount));
        emit Withdrawal(_msgSender(), _receiver, _indexes, totalAmount);
    }

    /**
     * @notice Claim rewards for multiple deposits
     * @param _indexes A list of deposit IDs to claim
     * @param _receiver Address to receive ETH
     */
    function claim(uint256[] calldata _indexes, address _receiver) external {
        if (_receiver == address(0)) revert OTSeaErrors.InvalidAddress();
        uint256 totalRewards = _claimMultiple(_indexes);
        _transferETHOrRevert(_receiver, totalRewards);
        emit Claimed(_msgSender(), _receiver, _indexes, totalRewards);
    }

    /**
     * @notice Compound rewards by swapping ETH for tokens and creating a new deposit
     * @param _indexes A list of deposit IDs to compound
     * @param _amountToSwap Amount of rewards (ETH) to swap for tokens, left over rewards are sent to _remainderReceiver
     * @param _minTokenAmount Minimum token amount to receive when swapping _amountToSwap
     * @param _remainderReceiver Address to receive any remaining rewards (can be the zero address if amountToSwap
     * is equal to the total rewards for _indexes)
     * @dev The staking contract is exempt from buy fees making compounding fee-free
     */
    function compound(
        uint256[] calldata _indexes,
        uint256 _amountToSwap,
        uint88 _minTokenAmount,
        address _remainderReceiver
    ) external {
        if (_amountToSwap == 0 || _minTokenAmount == 0) revert OTSeaErrors.InvalidAmount();
        uint256 totalRewards = _claimMultiple(_indexes);
        if (totalRewards < _amountToSwap) revert OTSeaErrors.InvalidAmount();
        uint256 remaining = totalRewards - _amountToSwap;
        if (remaining != 0) {
            if (_remainderReceiver == address(0)) revert OTSeaErrors.InvalidAddress();
            _transferETHOrRevert(_remainderReceiver, remaining);
            emit Claimed(_msgSender(), _remainderReceiver, _indexes, remaining);
        }
        uint88 tokens = _swapETHForTokens(_amountToSwap, _minTokenAmount);
        Deposit memory deposit = _createDeposit(tokens);
        emit Compounded(
            _msgSender(),
            _indexes,
            _amountToSwap,
            _deposits[_msgSender()].length - 1,
            deposit
        );
    }

    /**
     * @notice Get details about an epoch
     * @param _epoch Epoch ID (must be greater than 0 and not greater than the current epoch + 1)
     * @return Epoch Epoch details
     */
    function getEpoch(uint32 _epoch) external view returns (Epoch memory) {
        if (_epoch == 0 || _currentEpoch + 1 < _epoch) revert InvalidEpoch();
        return _epochs[_epoch];
    }

    /**
     * @notice Get the current epoch ID and details
     * @return uint32 Epoch ID
     * @return Epoch Epoch details
     */
    function getCurrentEpoch() external view returns (uint32, Epoch memory) {
        return (_currentEpoch, _epochs[_currentEpoch]);
    }

    /**
     * @notice Get the total deposits by a user
     * @param _account Account
     * @return total Total deposits by _account
     */
    function getTotalDeposits(address _account) public view returns (uint256 total) {
        if (_account == address(0)) revert OTSeaErrors.InvalidAddress();
        return _deposits[_account].length;
    }

    /**
     * @notice Get a deposit for a user by index
     * @param _account Account
     * @param _index Index of deposit
     * @return Deposit Deposit belonging to _account at index _index
     */
    function getDeposit(address _account, uint256 _index) external view returns (Deposit memory) {
        if (getTotalDeposits(_account) <= _index) revert DepositNotFound(_index);
        return _deposits[_account][_index];
    }

    /**
     * @notice Get a list of deposits for a user in a sequence from an start index to an end index (inclusive)
     * @param _account Account
     * @param _startIndex Start deposit index
     * @param _endIndex End deposit index
     * @return deposits A list of deposits for _account within the range of _startIndex and _endIndex (inclusive)
     */
    function getDepositsInSequence(
        address _account,
        uint256 _startIndex,
        uint256 _endIndex
    )
        external
        view
        onlyValidSequence(_startIndex, _endIndex, getTotalDeposits(_account), ALLOW_ZERO)
        returns (Deposit[] memory deposits)
    {
        deposits = new Deposit[](_endIndex - _startIndex + 1);
        uint256 index;
        uint256 depositIndex = _startIndex;
        for (depositIndex; depositIndex <= _endIndex; ) {
            deposits[index] = _deposits[_account][depositIndex];
            unchecked {
                index++;
                depositIndex++;
            }
        }
        return deposits;
    }

    /**
     * @notice Get a list of deposits for a user by providing a list
     * @param _account Account
     * @param _indexes A list of deposit indexes
     * @return deposits A list of deposits for _account based on the _indexes provided
     */
    function getDepositsByList(
        address _account,
        uint256[] calldata _indexes
    ) external view returns (Deposit[] memory deposits) {
        uint256 length = _indexes.length;
        _validateListLength(length);
        uint256 total = getTotalDeposits(_account);
        deposits = new Deposit[](length);
        for (uint256 i; i < length; ) {
            if (total <= _indexes[i]) revert DepositNotFound(_indexes[i]);
            deposits[i] = _deposits[_account][_indexes[i]];
            unchecked {
                i++;
            }
        }
        return deposits;
    }

    /**
     * @notice Calculate rewards for a user
     * @param _account Account
     * @param _indexes A list of deposit indexes
     * @return rewards Total rewards for _account based on the _indexes list
     */
    function calculateRewards(
        address _account,
        uint256[] calldata _indexes
    ) external view returns (uint256 rewards) {
        uint256 length = _indexes.length;
        _validateListLength(length);
        uint256 total = getTotalDeposits(_account);
        for (uint256 i; i < length; ) {
            if (total <= _indexes[i]) revert DepositNotFound(_indexes[i]);
            rewards += _calculateRewards(_account, _indexes[i]);
            unchecked {
                i++;
            }
        }
        return rewards;
    }

    function _nextEpoch() private {
        /// @dev sets the current epoch = the current while updating state to the next one
        uint32 nextEpoch = ++_currentEpoch;
        _epochs[nextEpoch].startedAt = uint88(block.timestamp);
        _epochs[nextEpoch].sharePerToken = _epochs[nextEpoch - 1].sharePerToken;
        _epochs[nextEpoch].totalStake += _epochs[nextEpoch - 1].totalStake;
    }

    /**
     * @param _amount Amount to deposit
     * @return deposit Deposit details
     */
    function _createDeposit(uint88 _amount) private returns (Deposit memory deposit) {
        uint32 nextEpoch = _currentEpoch + 1;
        deposit = Deposit(nextEpoch, _amount);
        _deposits[_msgSender()].push(deposit);
        _epochs[nextEpoch].totalStake += _amount;
        return deposit;
    }

    /**
     * @param _indexes A list of deposit indexes
     * @return totalAmount Total amount to withdraw based on _indexes
     * @return totalRewards Total amount of rewards based on _indexes
     */
    function _withdrawMultiple(
        uint256[] calldata _indexes
    ) private returns (uint88 totalAmount, uint256 totalRewards) {
        uint256 length = _indexes.length;
        _validateListLength(length);
        uint256 total = getTotalDeposits(_msgSender());
        uint32 currentEpoch = _currentEpoch;
        for (uint256 i; i < length; ) {
            if (total <= _indexes[i]) revert DepositNotFound(_indexes[i]);
            totalRewards += _calculateRewards(_msgSender(), _indexes[i]);
            Deposit memory deposit = _deposits[_msgSender()][_indexes[i]];
            if (deposit.rewardReferenceEpoch == 0) revert OTSeaErrors.NotAvailable();
            _deposits[_msgSender()][_indexes[i]].rewardReferenceEpoch = 0;
            /**
             * @dev if the rewardReferenceEpoch is in the future, it means that the user deposited in the current
             * epoch (currentEpoch). Therefore next epoch's total stake needs to be reduced by the user's deposit.
             *
             * If the rewardReferenceEpoch is less than or equal to the currentEpoch it means that the user
             * either deposited or claimed rewards in a past epoch. Either way it means that the user's
             * deposit cannot possible be in the future therefore the current epoch's total stake needs to be reduced
             */
            _epochs[
                currentEpoch < deposit.rewardReferenceEpoch
                    ? deposit.rewardReferenceEpoch
                    : currentEpoch
            ].totalStake -= deposit.amount;
            totalAmount += deposit.amount;
            unchecked {
                i++;
            }
        }
        return (totalAmount, totalRewards);
    }

    /**
     * @param _indexes A list of deposit indexes
     * @return totalRewards Total amount of rewards based on _indexes
     */
    function _claimMultiple(uint256[] calldata _indexes) private returns (uint256 totalRewards) {
        uint256 length = _indexes.length;
        _validateListLength(length);
        uint256 total = getTotalDeposits(_msgSender());
        uint32 currentEpoch = _currentEpoch;
        for (uint256 i; i < length; ) {
            if (total <= _indexes[i]) revert DepositNotFound(_indexes[i]);
            totalRewards += _calculateRewards(_msgSender(), _indexes[i]);
            _deposits[_msgSender()][_indexes[i]].rewardReferenceEpoch = currentEpoch;
            unchecked {
                i++;
            }
        }
        if (totalRewards == 0) revert NoRewards();
        return totalRewards;
    }

    /**
     * @param _amountToSwap Amount of ETH to swap for tokens
     * @param _minTokenAmount Minimum token amount to receive when swapping _amountToSwap
     * @return uint88 Tokens received
     */
    function _swapETHForTokens(
        uint256 _amountToSwap,
        uint88 _minTokenAmount
    ) private returns (uint88) {
        address[] memory path = new address[](2);
        path[0] = _router.WETH();
        path[1] = address(_otseaERC20);
        uint256[] memory amounts = _router.swapExactETHForTokens{value: _amountToSwap}(
            uint256(_minTokenAmount),
            path,
            address(this),
            block.timestamp
        );
        return uint88(amounts[1]);
    }

    /**
     * @param _account Account
     * @param _index Deposit index belonging to _account
     * @return uint256 Rewards accumulated by _account for deposit _index
     */
    function _calculateRewards(address _account, uint256 _index) private view returns (uint256) {
        uint32 rewardReferenceEpoch = _deposits[_account][_index].rewardReferenceEpoch;
        if (rewardReferenceEpoch == 0 || _currentEpoch <= rewardReferenceEpoch) {
            return 0;
        }
        return
            (_deposits[_account][_index].amount *
                (_epochs[_currentEpoch - 1].sharePerToken -
                    _epochs[rewardReferenceEpoch - 1].sharePerToken)) / REWARD_PRECISION;
    }

    /// @param _amount Amount
    function _checkSufficientAmount(uint88 _amount) private view {
        if (_otseaERC20.balanceOf(_msgSender()) < _amount)
            revert IERC20Errors.ERC20InsufficientBalance(
                _msgSender(),
                _otseaERC20.balanceOf(_msgSender()),
                uint256(_amount)
            );
        if (_otseaERC20.allowance(_msgSender(), address(this)) < _amount)
            revert IERC20Errors.ERC20InsufficientAllowance(
                address(this),
                _otseaERC20.allowance(_msgSender(), address(this)),
                uint256(_amount)
            );
    }

    /// @return bool true if initialized, false if not
    function _isInitialized() private view returns (bool) {
        return address(_otseaERC20) != address(0);
    }

    function _isCallerRevenueDistributor() private view {
        if (_msgSender() != _revenueDistributor) revert OTSeaErrors.Unauthorized();
    }
}
