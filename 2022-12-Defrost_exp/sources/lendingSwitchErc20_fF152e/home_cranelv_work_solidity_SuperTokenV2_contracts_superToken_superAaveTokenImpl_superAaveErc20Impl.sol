// SPDX-License-Identifier: GPL-3.0-or-later

pragma solidity ^0.7.0;
import "./superAaveTokenImpl.sol";
// superToken is the coolest vault in town. You come in with some token, and leave with more! The longer you stay, the more token you get.
//
// This contract handles swapping to and from superToken.
abstract contract superAaveErc20Impl is superAaveTokenImpl {
    using SafeERC20 for IERC20;
    constructor(address _lendingToken) superAaveTokenImpl(_lendingToken){
        asset = IERC20(IATokenV3(address(aavaToken)).UNDERLYING_ASSET_ADDRESS());
        asset.safeApprove(address(aavePool), uint(-1));
    }
}