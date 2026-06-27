// SPDX-License-Identifier: GPL-3.0-or-later

pragma solidity >=0.7.0 <0.8.0;

import "./superQiTokenImpl.sol";

//
// This contract handles swapping to and from superQiErc20
abstract contract superQiErc20Impl is superQiTokenImpl {
    using SafeERC20 for IERC20;
    using SafeMath for uint256;
    // Define the qiToken token contract
    constructor(address _lendingToken) superQiTokenImpl(_lendingToken){
        asset = IERC20(ICErc20(address(qiToken)).underlying());
        SafeERC20.safeApprove(asset, address(qiToken), uint(-1));
    }
    function onDeposit(address account,uint256 _amount,uint64 _fee)internal virtual override returns(uint256){
        asset.safeTransferFrom(account, address(this), _amount);
        return qiSupply(_fee);
    }
    function onWithdraw(address account,uint256 _amount)internal virtual override returns(uint256){
        uint256 success = ICErc20(address(qiToken)).redeemUnderlying(_amount);
        require(success == 0, "benqi redeem error");
        asset.safeTransfer(account, _amount);
        return _amount;
    }
    function qiWithdraw()internal{
        uint256 success = ICErc20(address(qiToken)).redeem(qiToken.balanceOf(address(this)));
        require(success == 0, "benqi redeem error");
    }
    function qiSupply(uint256 _fee) internal returns (uint256){
        uint256 balance = asset.balanceOf(address(this));
        if (balance>0){
            uint256 fee = balance.mul(_fee)/calDecimals;
            if (fee > 0){
                asset.safeTransfer(feePool,fee);
            }
            balance = balance.sub(fee);
            ICErc20(address(qiToken)).mint(balance);
            return balance;
        }
        return 0;
    }
    function onCompound() internal virtual override{
        claimRewards();
        qiSupply(feeRate[compoundFeeID]);
    }
}