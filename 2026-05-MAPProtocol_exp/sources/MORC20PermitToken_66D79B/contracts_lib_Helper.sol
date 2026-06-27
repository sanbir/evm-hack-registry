// SPDX-License-Identifier: MIT

pragma solidity ^0.8.9;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

library Helper {
    using SafeERC20 for IERC20;
    address internal constant ZERO_ADDRESS = address(0);

    address internal constant NATIVE_ADDRESS = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;

    function _isNative(address token) internal pure returns (bool) {
        return (token == ZERO_ADDRESS || token == NATIVE_ADDRESS);
    }

    function _getBalance(address _token, address _account) internal view returns (uint256) {
        if (_isNative(_token)) {
            return _account.balance;
        } else {
            return IERC20(_token).balanceOf(_account);
        }
    }

    function _transfer(address _token, address _to, uint256 _amount) internal {
        if (_isNative(_token)) {
            Address.sendValue(payable(_to), _amount);
        } else {
            IERC20(_token).safeTransfer(_to, _amount);
        }
    }

    function _safeWithdraw(address _wToken, uint _value) internal returns (bool) {
        (bool success, bytes memory data) = _wToken.call(abi.encodeWithSelector(0x2e1a7d4d, _value));
        return (success && (data.length == 0 || abi.decode(data, (bool))));
    }

    function _fromBytes(bytes memory bys) internal pure returns (address addr) {
        assembly {
            addr := mload(add(bys, 20))
        }
    }

    function _toBytes(address self) internal pure returns (bytes memory b) {
        b = abi.encodePacked(self);
    }
}
