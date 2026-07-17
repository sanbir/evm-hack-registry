// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.17;

import "@openzeppelin/contracts/interfaces/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

contract TransfererBase {
    using SafeERC20 for IERC20;

    function transferETH(address _recepient, uint256 _value) internal {
        (bool success, ) = _recepient.call{value: _value}("");
        require(success, "Transfer Failed");
    }

    function transferERC20Token(
        address _erc20TokenAddress,
        address _to,
        uint256 _value
    ) internal {
        IERC20(_erc20TokenAddress).safeTransfer(_to, _value);
    }

    function approveERC20Token(
        address _erc20TokenAddress,
        address _to,
        uint256 _value
    ) internal {
        IERC20(_erc20TokenAddress).safeApprove(_to, 0);
        IERC20(_erc20TokenAddress).safeApprove(_to, _value);
    }

    function approveUnlimited(
        address _erc20TokenAddress,
        address _to
    ) internal {
        if (
            IERC20(_erc20TokenAddress).allowance(address(this), _to) <
            type(uint256).max / 2
        ) {
            IERC20(_erc20TokenAddress).safeApprove(_to, 0);
            IERC20(_erc20TokenAddress).safeApprove(_to, type(uint256).max);
        }
    }
}
