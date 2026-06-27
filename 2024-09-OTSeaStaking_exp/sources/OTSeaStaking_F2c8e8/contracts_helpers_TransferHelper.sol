/*
        [....     [... [......  [.. ..
      [..    [..       [..    [..    [..
    [..        [..     [..     [..         [..       [..
    [..        [..     [..       [..     [.   [..  [..  [..
    [..        [..     [..          [.. [..... [..[..   [..
      [..     [..      [..    [..    [..[.        [..   [..
        [....          [..      [.. ..    [....     [.. [...

    https://otsea.io
    https://t.me/OTSeaPortal
    https://twitter.com/OTSeaERC20
*/

// SPDX-License-Identifier: MIT
pragma solidity =0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/Context.sol";
import "contracts/libraries/OTSeaErrors.sol";

/// @title A transfer helper contract for ETH and tokens
contract TransferHelper is Context {
    using SafeERC20 for IERC20;

    /// @dev account -> Amount of ETH that failed to transfer
    mapping(address => uint256) private _maroonedETH;

    error NativeTransferFailed();

    event MaroonedETH(address account, uint256 amount);
    event MaroonedETHClaimed(address account, address receiver, uint256 amount);

    /**
     * @notice Claim marooned ETH
     * @param _receiver Address to receive the marooned ETH
     */
    function claimMaroonedETH(address _receiver) external {
        if (_receiver == address(0)) revert OTSeaErrors.InvalidAddress();
        uint256 amount = _maroonedETH[_msgSender()];
        if (amount == 0) revert OTSeaErrors.NotAvailable();
        _maroonedETH[_msgSender()] = 0;
        _transferETHOrRevert(_receiver, amount);
        emit MaroonedETHClaimed(_msgSender(), _receiver, amount);
    }

    /**
     * @notice Get the amount of marooned ETH for an account
     * @param _account Account to check
     * @return uint256 Marooned ETH
     */
    function getMaroonedETH(address _account) external view returns (uint256) {
        if (_account == address(0)) revert OTSeaErrors.InvalidAddress();
        return _maroonedETH[_account];
    }

    /**
     * @param _account Account to transfer ETH to
     * @param _amount Amount of ETH to transfer to _account
     * @dev Rather than reverting if the transfer fails, the _amount is stored for the _account to later claim
     */
    function _safeETHTransfer(address _account, uint256 _amount) internal {
        (bool success, ) = _account.call{value: _amount}("");
        if (!success) {
            _maroonedETH[_account] += _amount;
            emit MaroonedETH(_account, _amount);
        }
    }

    /**
     * @param _account Account to transfer ETH to
     * @param _amount Amount of ETH to transfer to _account
     * @dev The following will revert if the transfer fails
     */
    function _transferETHOrRevert(address _account, uint256 _amount) internal {
        (bool success, ) = _account.call{value: _amount}("");
        if (!success) revert NativeTransferFailed();
    }

    /**
     * @param _token Token to transfer into the contract from msg.sender
     * @param _amount Amount of _token to transfer
     * @return uint256 Actual amount transferred into the contract
     * @dev This function exists due to _token potentially having taxes
     */
    function _transferInTokens(IERC20 _token, uint256 _amount) internal returns (uint256) {
        uint256 balanceBefore = _token.balanceOf(address(this));
        _token.safeTransferFrom(_msgSender(), address(this), _amount);
        return _token.balanceOf(address(this)) - balanceBefore;
    }
}
