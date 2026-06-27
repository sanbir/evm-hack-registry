// SPDX-License-Identifier: MIT
pragma solidity 0.8.19;

interface ITimelock {
  /** @notice Event emitted when a new time-lock agreement is created
   * @param agreementId ID of the created agreement
   * @param actionType Type of action for the time-lock
   * @param asset Address of the asset
   * @param amount  amount
   * @param beneficiary Address of the beneficiary
   * @param releaseTime Timestamp when the assets can be claimed
   */
  event AgreementCreated(
    uint256 agreementId,
    TimeLockActionType actionType,
    address indexed asset,
    uint256 amount,
    address indexed beneficiary,
    uint256 releaseTime
  );

  /** @notice Event emitted when a time-lock agreement is claimed
   * @param agreementId ID of the claimed agreement
   * @param actionType Type of action for the time-lock
   * @param asset Address of the asset
   * @param amount amount
   * @param beneficiary Address of the beneficiary
   */
  event AgreementClaimed(
    uint256 agreementId,
    TimeLockActionType actionType,
    address indexed asset,
    uint256 amount,
    address indexed beneficiary
  );

  /** @notice Event emitted when a time-lock agreement is frozen or unfrozen
   * @param agreementId ID of the affected agreement
   * @param value Indicates whether the agreement is frozen (true) or unfrozen (false)
   */
  event AgreementFrozen(uint256 agreementId, bool value);

  /** @notice Event emitted when the entire TimeLock contract is frozen or unfrozen
   * @param value Indicates whether the contract is frozen (true) or unfrozen (false)
   */
  event TimeLockFrozen(bool value);

  /**
   * @dev Emitted during rescueERC20()
   * @param token The address of the token
   * @param to The address of the recipient
   * @param amount The amount being rescued
   **/
  event RescueERC20(address indexed token, address indexed to, uint256 amount);

  enum TimeLockActionType {
    BORROW,
    REDEEM
  }
  struct Agreement {
    uint256 agreementId;
    TimeLockActionType actionType;
    address underlying;
    bool isFrozen;
    address beneficiary;
    uint256 releaseTime;
    uint256 amount;
  }

  struct Underlying {
    address cToken;
    uint256 totalBalance;
    uint256 lockDuration;
    bool isSupport;
  }

  function createAgreement(
    TimeLockActionType actionType,
    address underlying,
    uint256 amount,
    address beneficiary
  ) external returns (uint256);

  function isSupport(address underlying) external view returns (bool);
}
