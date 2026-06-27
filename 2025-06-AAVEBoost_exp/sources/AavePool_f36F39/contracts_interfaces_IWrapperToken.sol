//SPDX-License-Identifier: Unlicense
pragma solidity 0.8.4;

import "@openzeppelin/contracts-upgradeable/token/ERC20/IERC20Upgradeable.sol";

interface IWrapperToken is IERC20Upgradeable {
    function mint(address, uint256) external;

    function burn(address, uint256) external;

    function getAccountSnapshot(address user)
        external
        view
        returns (uint256[] memory, uint256[] memory);

    function getDepositAt(address user, uint256 blockNumber) external view returns (uint256 amount);

    function initialize(address underlying_) external;

    /// @dev emitted on update account snapshot
    event UpdateSnapshot(
        address indexed user,
        uint256 oldValue,
        uint256 newValue,
        uint256 timestamp
    );
}
