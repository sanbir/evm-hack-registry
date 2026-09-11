// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.10;

import {SafeCast} from '../../../dependencies/openzeppelin/contracts/SafeCast.sol';
import {Errors} from '../../libraries/helpers/Errors.sol';
import {WadRayMath} from '../../libraries/math/WadRayMath.sol';
import {IPool} from '../../../interfaces/IPool.sol';
import {IScaledBalanceToken} from '../../../interfaces/IScaledBalanceToken.sol';
import {MintableIncentivizedERC20} from './MintableIncentivizedERC20.sol';

/**
 * @title ScaledBalanceTokenBase
 * @author Aave
 * @notice Basic ERC20 implementation of scaled balance token
 */
abstract contract ScaledBalanceTokenBase is MintableIncentivizedERC20, IScaledBalanceToken {
  using WadRayMath for uint256;
  using SafeCast for uint256;

  /**
   * @dev Constructor.
   * @param pool The reference to the main Pool contract
   * @param name The name of the token
   * @param symbol The symbol of the token
   * @param decimals The number of decimals of the token
   */
  constructor(
    IPool pool,
    string memory name,
    string memory symbol,
    uint8 decimals
  ) MintableIncentivizedERC20(pool, name, symbol, decimals) {
    // Intentionally left blank
  }

  /// @inheritdoc IScaledBalanceToken
  function scaledBalanceOf(address user) external view override returns (uint256) {
    return super.balanceOf(user);
  }

  /// @inheritdoc IScaledBalanceToken
  function getScaledUserBalanceAndSupply(
    address user
  ) external view override returns (uint256, uint256) {
    return (super.balanceOf(user), super.totalSupply());
  }

  /// @inheritdoc IScaledBalanceToken
  function scaledTotalSupply() public view virtual override returns (uint256) {
    return super.totalSupply();
  }

  /// @inheritdoc IScaledBalanceToken
  function getPreviousIndex(address user) external view virtual override returns (uint256) {
    return _userState[user].additionalData;
  }

  /**
   * @notice Converts an underlying `amount` into a scaled amount when minting.
   * @dev Default rounds half up (legacy behaviour). AToken overrides to floor and
   * VariableDebtToken to ceil, matching Aave v3.5 predictable rounding.
   * @param amount The underlying amount being minted
   * @param index The reserve index (liquidity index for aTokens, borrow index for vTokens)
   * @return The scaled amount
   */
  function _scaleForMint(uint256 amount, uint256 index) internal pure virtual returns (uint256) {
    return amount.rayDiv(index);
  }

  /**
   * @notice Converts an underlying `amount` into a scaled amount when burning.
   * @dev Default rounds half up (legacy behaviour). AToken overrides to ceil and
   * VariableDebtToken to floor, matching Aave v3.5 predictable rounding.
   * @param amount The underlying amount being burned
   * @param index The reserve index (liquidity index for aTokens, borrow index for vTokens)
   * @return The scaled amount
   */
  function _scaleForBurn(uint256 amount, uint256 index) internal pure virtual returns (uint256) {
    return amount.rayDiv(index);
  }

  /**
   * @notice Converts a `scaledAmount` into its current underlying balance.
   * @dev Default rounds half up (legacy behaviour). AToken overrides to floor and
   * VariableDebtToken to ceil, matching Aave v3.5 predictable rounding.
   * @param scaledAmount The scaled balance
   * @param index The reserve index (liquidity index for aTokens, borrow index for vTokens)
   * @return The underlying balance
   */
  function _balanceFromScaled(
    uint256 scaledAmount,
    uint256 index
  ) internal pure virtual returns (uint256) {
    return scaledAmount.rayMul(index);
  }

  /**
   * @notice Implements the basic logic to mint a scaled balance token.
   * @param caller The address performing the mint
   * @param onBehalfOf The address of the user that will receive the scaled tokens
   * @param amount The amount of tokens getting minted
   * @param index The next liquidity index of the reserve
   * @return `true` if the the previous balance of the user was 0
   */
  function _mintScaled(
    address caller,
    address onBehalfOf,
    uint256 amount,
    uint256 index
  ) internal returns (bool) {
    uint256 amountScaled = _scaleForMint(amount, index);
    require(amountScaled != 0, Errors.INVALID_MINT_AMOUNT);

    uint256 scaledBalance = super.balanceOf(onBehalfOf);
    uint256 balanceIncrease = _balanceFromScaled(scaledBalance, index) -
      _balanceFromScaled(scaledBalance, _userState[onBehalfOf].additionalData);

    _userState[onBehalfOf].additionalData = index.toUint128();

    _mint(onBehalfOf, amountScaled.toUint128());

    uint256 amountToMint = amount + balanceIncrease;
    emit Transfer(address(0), onBehalfOf, amountToMint);
    emit Mint(caller, onBehalfOf, amountToMint, balanceIncrease, index);

    return (scaledBalance == 0);
  }

  /**
   * @notice Implements the basic logic to burn a scaled balance token.
   * @dev In some instances, a burn transaction will emit a mint event
   * if the amount to burn is less than the interest that the user accrued
   * @param user The user which debt is burnt
   * @param target The address that will receive the underlying, if any
   * @param amount The amount getting burned
   * @param index The variable debt index of the reserve
   */
  function _burnScaled(address user, address target, uint256 amount, uint256 index) internal {
    uint256 amountScaled = _scaleForBurn(amount, index);
    require(amountScaled != 0, Errors.INVALID_BURN_AMOUNT);

    uint256 scaledBalance = super.balanceOf(user);
    // Safety guard: ceil-rounding the burn (aToken withdraw/liquidation) can overshoot
    // the user's scaled balance by 1 wei because SupplyLogic sizes `amount` with a
    // half-up rayMul. Cap the scaled burn to avoid underflowing `_burn` on withdraw(max)
    // / full liquidation. For floor-rounding callers (vToken repay) this is a no-op.
    if (amountScaled > scaledBalance) {
      amountScaled = scaledBalance;
    }
    uint256 balanceIncrease = _balanceFromScaled(scaledBalance, index) -
      _balanceFromScaled(scaledBalance, _userState[user].additionalData);

    _userState[user].additionalData = index.toUint128();

    _burn(user, amountScaled.toUint128());

    if (balanceIncrease > amount) {
      uint256 amountToMint = balanceIncrease - amount;
      emit Transfer(address(0), user, amountToMint);
      emit Mint(user, user, amountToMint, balanceIncrease, index);
    } else {
      uint256 amountToBurn = amount - balanceIncrease;
      emit Transfer(user, address(0), amountToBurn);
      emit Burn(user, target, amountToBurn, balanceIncrease, index);
    }
  }

  /**
   * @notice Implements the basic logic to transfer scaled balance tokens between two users
   * @dev It emits a mint event with the interest accrued per user
   * @param sender The source address
   * @param recipient The destination address
   * @param amount The amount getting transferred
   * @param index The next liquidity index of the reserve
   */
  function _transfer(address sender, address recipient, uint256 amount, uint256 index) internal {
    uint256 senderScaledBalance = super.balanceOf(sender);
    uint256 senderBalanceIncrease = _balanceFromScaled(senderScaledBalance, index) -
      _balanceFromScaled(senderScaledBalance, _userState[sender].additionalData);

    uint256 recipientScaledBalance = super.balanceOf(recipient);
    uint256 recipientBalanceIncrease = _balanceFromScaled(recipientScaledBalance, index) -
      _balanceFromScaled(recipientScaledBalance, _userState[recipient].additionalData);

    _userState[sender].additionalData = index.toUint128();
    _userState[recipient].additionalData = index.toUint128();

    // aTokens round the transferred scaled amount up (ceil) so the sender's scaled
    // balance is reduced by at least the requested value; cap to the sender's scaled
    // balance to avoid a 1-wei overshoot underflowing the transfer. (vTokens are
    // non-transferable, so this path is exercised by aTokens only.)
    uint256 amountScaled = amount.rayDivCeil(index);
    if (amountScaled > senderScaledBalance) {
      amountScaled = senderScaledBalance;
    }
    super._transfer(sender, recipient, amountScaled.toUint128());

    if (senderBalanceIncrease > 0) {
      emit Transfer(address(0), sender, senderBalanceIncrease);
      emit Mint(_msgSender(), sender, senderBalanceIncrease, senderBalanceIncrease, index);
    }

    if (sender != recipient && recipientBalanceIncrease > 0) {
      emit Transfer(address(0), recipient, recipientBalanceIncrease);
      emit Mint(_msgSender(), recipient, recipientBalanceIncrease, recipientBalanceIncrease, index);
    }

    emit Transfer(sender, recipient, amount);
  }
}
