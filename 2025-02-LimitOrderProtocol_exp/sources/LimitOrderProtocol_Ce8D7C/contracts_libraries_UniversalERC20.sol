// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@openzeppelin/contracts-upgradeable/token/ERC20/IERC20Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/utils/SafeERC20Upgradeable.sol";


library UniversalERC20 {
    using SafeERC20Upgradeable for IERC20Upgradeable;
    IERC20Upgradeable internal constant ZERO_ADDRESS = IERC20Upgradeable(0x0000000000000000000000000000000000000000);
    IERC20Upgradeable internal constant ETH_ADDRESS = IERC20Upgradeable(0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE);
    IERC20Upgradeable internal constant MATIC_ADDRESS = IERC20Upgradeable(0x0000000000000000000000000000000000001010);


    function isETH(IERC20Upgradeable token) internal pure returns (bool) {
        return
        address(token) == address(ETH_ADDRESS) ||
        address(token) == address(MATIC_ADDRESS) ||
        address(token) == address(ZERO_ADDRESS);
    }

    function universalTransfer(IERC20Upgradeable token, address to, uint amount) internal {
        if (isETH(token)) {
            payable(to).transfer(amount);
        } else {
            IERC20Upgradeable(token).safeTransfer(to, amount);
        }
    }
}
