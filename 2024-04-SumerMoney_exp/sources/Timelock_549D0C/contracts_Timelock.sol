// SPDX-License-Identifier: MIT
pragma solidity 0.8.19;

import '@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol';
import '@openzeppelin/contracts/access/AccessControlEnumerable.sol';
import '@openzeppelin/contracts/security/ReentrancyGuard.sol';
import '@openzeppelin/contracts/utils/Address.sol';
import './ITimelock.sol';

interface ICToken {
  function underlying() external view returns (address);

  function isCEther() external view returns (bool);
}

contract Timelock is ITimelock, AccessControlEnumerable, ReentrancyGuard {
  using SafeERC20 for IERC20;
  using EnumerableSet for EnumerableSet.UintSet;

  bytes32 public constant EMERGENCY_ADMIN = keccak256('EMERGENCY_ADMIN');
  /// @notice user => agreements ids set
  mapping(address => EnumerableSet.UintSet) private _userAgreements;
  /// @notice ids => agreement
  mapping(uint256 => Agreement) private agreements;
  /// @notice cToken => underlying
  mapping(address => address) public cTokenToUnderlying;
  /// @notice underlying => underlyDetial
  mapping(address => Underlying) public underlyingDetail;
  uint256 public agreementCount;
  bool public frozen;

  constructor(address[] memory cTokens) {
    for (uint i; i < cTokens.length; ++i) {
      address cToken = cTokens[i];
      require(cToken != address(0), 'cToken is zero');
      address underlying;
      if (ICToken(cToken).isCEther()) {
        underlying = address(1);
      } else {
        underlying = ICToken(cToken).underlying();
      }
      require(underlying != address(0), 'underlying is zero');
      cTokenToUnderlying[cToken] = underlying;
      underlyingDetail[underlying].cToken = cToken;
      underlyingDetail[underlying].isSupport = true;
    }
    _setupRole(DEFAULT_ADMIN_ROLE, msg.sender);
    _setupRole(EMERGENCY_ADMIN, msg.sender);
  }

  receive() external payable {}

  modifier onlyAdmin() {
    require(hasRole(DEFAULT_ADMIN_ROLE, msg.sender), 'CALLER_NOT_ADMIN');
    _;
  }

  modifier onlyEmergencyAdmin() {
    require(hasRole(EMERGENCY_ADMIN, msg.sender), 'CALLER_NOT_EMERGENCY_ADMIN');
    _;
  }

  modifier onlyCToken(address underlying) {
    require(cTokenToUnderlying[msg.sender] == underlying && underlying != address(0), 'CALLER_NOT_CTOKEN');
    require(underlyingDetail[underlying].isSupport, 'NOT_SUPPORT');
    _;
  }

  function setUnderly(address cToken, address underlying, bool isSupport) external onlyAdmin {
    cTokenToUnderlying[cToken] = underlying;
    underlyingDetail[underlying].cToken = cToken;
    underlyingDetail[underlying].isSupport = isSupport;
  }

  function setLockDuration(address underlying, uint256 lockDuration) external onlyAdmin {
    underlyingDetail[underlying].lockDuration = lockDuration;
  }

  function rescueERC20(address token, address to, uint256 amount) external onlyEmergencyAdmin {
    IERC20(token).safeTransfer(to, amount);
    emit RescueERC20(token, to, amount);
  }

  function createAgreement(
    TimeLockActionType actionType,
    address underlying,
    uint256 amount,
    address beneficiary
  ) external onlyCToken(underlying) returns (uint256) {
    require(beneficiary != address(0), 'Beneficiary cant be zero address');
    uint256 underlyBalance;
    if (underlying == address(1)) {
      underlyBalance = address(this).balance;
    } else {
      underlyBalance = IERC20(underlying).balanceOf(address(this));
    }
    require(underlyBalance >= underlyingDetail[underlying].totalBalance + amount, 'balance error');
    underlyingDetail[underlying].totalBalance = underlyBalance;

    uint256 agreementId = agreementCount++;
    uint256 releaseTime = block.timestamp + underlyingDetail[underlying].lockDuration;
    agreements[agreementId] = Agreement({
      actionType: actionType,
      underlying: underlying,
      amount: amount,
      beneficiary: beneficiary,
      releaseTime: releaseTime,
      isFrozen: false,
      agreementId: agreementId
    });
    _userAgreements[beneficiary].add(agreementId);

    emit AgreementCreated(agreementId, actionType, underlying, amount, beneficiary, releaseTime);
    return agreementId;
  }

  function _validateAndDeleteAgreement(uint256 agreementId) internal returns (Agreement memory) {
    Agreement memory agreement = agreements[agreementId];
    require(msg.sender == agreement.beneficiary, 'Not beneficiary');
    require(block.timestamp >= agreement.releaseTime, 'Release time not reached');
    require(!agreement.isFrozen, 'Agreement frozen');
    delete agreements[agreementId];
    _userAgreements[agreement.beneficiary].remove(agreementId);

    emit AgreementClaimed(
      agreementId,
      agreement.actionType,
      agreement.underlying,
      agreement.amount,
      agreement.beneficiary
    );

    return agreement;
  }

  function claim(uint256[] calldata agreementIds) external nonReentrant {
    require(!frozen, 'TimeLock is frozen');

    for (uint256 index = 0; index < agreementIds.length; index++) {
      Agreement memory agreement = _validateAndDeleteAgreement(agreementIds[index]);
      if (agreement.underlying == address(1)) {
        // payable(agreement.beneficiary).transfer(agreement.amount);
        Address.sendValue(payable(agreement.beneficiary), agreement.amount);
      } else {
        IERC20(agreement.underlying).safeTransfer(agreement.beneficiary, agreement.amount);
      }
      underlyingDetail[agreement.underlying].totalBalance -= agreement.amount;
    }
  }

  function underlyingDetails(address[] calldata underlyings) external view returns (Underlying[] memory) {
    uint256 underlyingLength = underlyings.length;
    Underlying[] memory underlyingDetails = new Underlying[](underlyingLength);
    for (uint256 i; i < underlyingLength; ++i) {
      underlyingDetails[i] = underlyingDetail[underlyings[i]];
    }
    return underlyingDetails;
  }

  function userAgreements(address user) external view returns (Agreement[] memory) {
    uint256 agreementLength = _userAgreements[user].length();
    Agreement[] memory userAgreements = new Agreement[](agreementLength);
    for (uint256 i; i < agreementLength; ++i) {
      userAgreements[i] = agreements[_userAgreements[user].at(i)];
    }
    return userAgreements;
  }

  function isSupport(address underlying) external view returns (bool) {
    return underlyingDetail[underlying].isSupport;
  }

  function freezeAgreement(uint256 agreementId) external onlyEmergencyAdmin {
    agreements[agreementId].isFrozen = true;
    emit AgreementFrozen(agreementId, true);
  }

  function freezeAllAgreements() external onlyEmergencyAdmin {
    frozen = true;
    emit TimeLockFrozen(true);
  }

  function unfreezeAllAgreements() external onlyAdmin {
    frozen = false;
    emit TimeLockFrozen(false);
  }
}
