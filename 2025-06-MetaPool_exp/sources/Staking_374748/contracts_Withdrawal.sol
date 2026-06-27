// SPDX-License-Identifier: MIT
pragma solidity 0.8.4;

import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC4626Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/utils/SafeERC20Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/AddressUpgradeable.sol";
import "./Staking.sol";

struct withdrawRequest {
    uint256 amount;
    uint256 unlockEpoch;
    address receiver;
}

/// @title Manage withdrawals from validators to users
/// @notice Receive request for withdrawals from Staking and allow users to complete the withdrawals once the epoch is reached
/// @dev As the disassemble of validators is delayed, this contract manage the pending withdraw from users to allow the to complet it once his unlockEpoch is reached and if the contract has enough ETH
// The epochs are of one week
contract Withdrawal is OwnableUpgradeable {
    using AddressUpgradeable for address payable;
    using SafeERC20Upgradeable for IERC20Upgradeable;

    address payable public mpETH;
    // How much do we owe to delayed withdrawals
    uint256 public totalPendingWithdraw;
    uint256 public startTimestamp;
    mapping(address => withdrawRequest) public pendingWithdraws;
    uint8 public withdrawalsStartEpoch;
    uint32 public constant MAX_VALIDATORS_DISASSEMBLE_TIME = 90 days;
    uint32 public validatorsDisassembleTime;

    event RequestWithdraw(
        address indexed caller,
        uint256 amount,
        address receiver,
        uint256 unlockEpoch
    );
    event CompleteWithdraw(
        address indexed caller,
        uint256 amount,
        address receiver,
        uint256 unlockEpoch
    );

    error NotAuthorized(address _caller, address _authorized);
    error EpochNotReached(uint256 _currentEpoch, uint256 _unlockEpoch);
    error UserDontHavePendingWithdraw(address _user);
    error NotEnoughETHtoStake(uint256 _requested, uint256 _available);
    error WithdrawalsNotStarted(uint256 _currentEpoch, uint256 _startEpoch);
    error ClaimTooSoon(uint256 timestampUnlock);
    error InvalidConfig(uint256 valueSent, uint256 maxValue);

    modifier onlyStaking() {
        if (msg.sender != mpETH) revert NotAuthorized(msg.sender, mpETH);
        _;
    }

    receive() external payable {}

    function initialize(address payable _mpETH) external initializer {
        require(address(this).balance == 0, "Error initialize with no zero balance");
        __Ownable_init();
        startTimestamp = block.timestamp;
        mpETH = _mpETH;
        setWithdrawalsStartEpoch(8);
        setValidatorsDisassembleTime(7 days);
    }

    /// @return epoch Current epoch
    function getEpoch() public view returns (uint256 epoch) {
        return (block.timestamp - startTimestamp) / 7 days;
    }

    /// @return Timestamp until next epoch
    function getEpochTimeLeft() external view returns (uint256) {
        return startTimestamp + (getEpoch() + 1) * 7 days - block.timestamp;
    }

    function getEpochStartTime(uint256 _epoch) public view returns (uint256) {
        return startTimestamp + _epoch * 7 days;
    }

    /// @notice Set first epoch for allow withdrawals
    function setWithdrawalsStartEpoch(uint8 _epoch) public onlyOwner {
        if (_epoch > 32) revert InvalidConfig(_epoch, 32);
        withdrawalsStartEpoch = _epoch;
    }

    /// @notice Set estimated time for validators disassemble
    function setValidatorsDisassembleTime(uint32 _disassembleTime) public onlyOwner {
        if (_disassembleTime > MAX_VALIDATORS_DISASSEMBLE_TIME)
            revert InvalidConfig(_disassembleTime, MAX_VALIDATORS_DISASSEMBLE_TIME);
        validatorsDisassembleTime = _disassembleTime;
    }

    /// @notice Queue ETH withdrawal
    /// @dev Multiples withdrawals are accumulative, but will restart the epoch unlock
    /// Shares used for this request should be already bruned in the calling function (Staking._withdraw)
    /// @param _amountOut ETH amount to withdraw
    /// @param _user Owner of the withdrawal
    function requestWithdraw(
        uint256 _amountOut,
        address _user,
        address _receiver
    ) external onlyStaking {
        uint256 currentEpoch = getEpoch();
        if (currentEpoch < withdrawalsStartEpoch)
            revert WithdrawalsNotStarted(currentEpoch, withdrawalsStartEpoch);
        uint256 unlockEpoch = currentEpoch + 1;
        pendingWithdraws[_user].amount += _amountOut;
        pendingWithdraws[_user].unlockEpoch = unlockEpoch;
        pendingWithdraws[_user].receiver = _receiver;
        totalPendingWithdraw += _amountOut;
        emit RequestWithdraw(_user, _amountOut, _receiver, unlockEpoch);
    }

    /// @notice Process pending withdrawal if there's enough ETH
    function completeWithdraw() external {
        withdrawRequest memory _withdrawR = pendingWithdraws[msg.sender];

        if (_withdrawR.amount == 0) revert UserDontHavePendingWithdraw(msg.sender);

        uint256 unlockTime = getEpochStartTime(_withdrawR.unlockEpoch) + validatorsDisassembleTime;
        if (block.timestamp < unlockTime) revert ClaimTooSoon(unlockTime);

        if (_withdrawR.receiver == address(0)) _withdrawR.receiver = msg.sender;
        totalPendingWithdraw -= _withdrawR.amount;
        delete pendingWithdraws[msg.sender];
        payable(_withdrawR.receiver).sendValue(_withdrawR.amount);
        emit CompleteWithdraw(
            msg.sender,
            _withdrawR.amount,
            _withdrawR.receiver,
            _withdrawR.unlockEpoch
        );
    }

    /// @notice Send ETH _amount to Staking
    /// @dev As the validators are always fully disassembled, the contract can have more ETH than the needed for withdrawals. So the Staking can take this ETH and send it again to validators. This shouldn't mint new mpETH
    function getEthForValidator(uint256 _amount) external onlyStaking {
        if (totalPendingWithdraw > address(this).balance) revert NotEnoughETHtoStake(_amount, 0);
        uint256 ethRemaining = address(this).balance - totalPendingWithdraw;
        if (_amount > ethRemaining) revert NotEnoughETHtoStake(_amount, ethRemaining);
        mpETH.sendValue(_amount);
    }
}
