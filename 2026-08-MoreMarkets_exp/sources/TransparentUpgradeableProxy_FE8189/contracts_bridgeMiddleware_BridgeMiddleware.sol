// SPDX-License-Identifier: BSD-3-Clause
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Context} from "@openzeppelin/contracts/utils/Context.sol";
import {Storage} from "../storage/Storage.sol";

contract BridgeMiddleware is Context, Initializable {
  using SafeERC20 for IERC20;

  address public info;

  address public owner;

  event Deposit(address indexed token, uint256 amount);

  error Forbidden();

  error BridgeNotFound();

  error DepositFailed();

  receive() external payable {}

  fallback() external payable {}

  constructor() {
    _disableInitializers();
  }

  function initialize(address _info, address _owner) external initializer {
    info = _info;
    owner = _owner;
  }

  function _safeApprove(address token, address spender, uint256 amount) internal {
    uint256 allowance = IERC20(token).allowance(address(this), spender);
    if (allowance >= amount) return;

    IERC20(token).approve(spender, 0);
    IERC20(token).approve(spender, amount);
  }

  function deposit(address token, uint256 amount, bytes memory data) external {
    bool isCallAllowed = Storage(info).getBool(
      keccak256(abi.encodePacked("EH:BridgeMiddleware:Depositor:", _msgSender()))
    );
    if (!isCallAllowed) revert Forbidden();

    address bridge = Storage(info).getAddress(keccak256("EH:BridgeMiddleware:Bridge"));
    if (bridge == address(0)) revert BridgeNotFound();

    bool success;
    if (token == address(0)) {
      // solhint-disable-next-line avoid-low-level-calls
      (success, ) = bridge.call{value: amount}(data);
    } else {
      _safeApprove(token, bridge, amount);
      // solhint-disable-next-line avoid-low-level-calls
      (success, ) = bridge.call(data);
    }
    if (!success) revert DepositFailed();

    emit Deposit(token, amount);
  }
}
