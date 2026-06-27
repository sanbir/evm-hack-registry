// SPDX-License-Identifier: GPL-3.0-or-later

pragma solidity >=0.7.0 <0.8.0;
import "../superAaveTokenImpl/superAaveErc20Impl.sol";
import "../superQiTokenImpl/superQiErc20Impl.sol";
import "../baseSuperToken.sol";
// superToken is the coolest vault in town. You come in with some token, and leave with more! The longer you stay, the more token you get.
//
// This contract handles swapping to and from superToken.
contract superSwitchErc20 is baseSuperToken,superAaveErc20Impl,superQiErc20Impl{    
    uint8 public lendingSwitch; 
    event Switch(address indexed sender,uint8 lendingSwitch);
    constructor(address multiSignature,address origin0,address origin1,address _aavaToken,address _qiToken,
        address payable _swapHelper,address payable _feePool,uint8 _lendingSwitch)
        baseSuperToken(multiSignature,origin0,origin1,_swapHelper,_feePool)superAaveErc20Impl(_aavaToken) superQiErc20Impl(_qiToken){
        lendingSwitch = _lendingSwitch;
        setTokenInfo("Super ","S");
    }
    function getMidText()internal virtual override(superAaveTokenImpl,superQiTokenImpl,superTokenInterface) returns(string memory,string memory){
        return ("Switch ","SW");
    }
    function switchToBenqi()external onlyOrigin{
        require(lendingSwitch == 0, "On benqi Lending");
        lendingSwitch = 1;
        aaveWithdraw();
        qiSupply(0);
        emit Switch(msg.sender,1);
    }
    function switchToAave()external onlyOrigin{
        require(lendingSwitch == 1, "On Aave Lending");
        lendingSwitch = 0;
        qiWithdraw();
        aaveSupply(0);
        emit Switch(msg.sender,0);
    }
    function setReward(uint256 index,uint8 _reward,bool _bClosed,address _rewardToken,uint256 _sellLimit)  external onlyOrigin {
        if (lendingSwitch == 0){
            setAaveRewardToken(index,_reward,_bClosed,_rewardToken,_sellLimit);
        }else{
            setBenqiRewardToken(index,_reward,_bClosed,_rewardToken,_sellLimit);
        }
    }
    function getAvailableBalance() internal virtual override(superAaveTokenImpl,superQiTokenImpl,superTokenInterface) view returns (uint256){
        if (lendingSwitch == 0){
            return superAaveTokenImpl.getAvailableBalance();
        }else{
            return superQiTokenImpl.getAvailableBalance();
        }
    }
    function getTotalAssets() internal virtual override(superAaveTokenImpl,superQiTokenImpl,superTokenInterface) view returns (uint256){
        if (lendingSwitch == 0){
            return superAaveTokenImpl.getTotalAssets();
        }else{
            return superQiTokenImpl.getTotalAssets();
        }
    }
    function onDeposit(address account,uint256 _amount,uint64 _fee)internal virtual override(superAaveTokenImpl,superQiErc20Impl,superTokenInterface) returns(uint256){
        if (lendingSwitch == 0){
            return superAaveTokenImpl.onDeposit(account,_amount,_fee);
        }else{
            return superQiErc20Impl.onDeposit(account,_amount,_fee);
        }
    }
    function onWithdraw(address account,uint256 _amount)internal virtual override(superAaveTokenImpl,superQiErc20Impl,superTokenInterface) returns(uint256){
        if (lendingSwitch == 0){
            return superAaveTokenImpl.onWithdraw(account,_amount);
        }else{
            return superQiErc20Impl.onWithdraw(account,_amount);
        }
    }
    function onCompound() internal virtual override(superAaveTokenImpl,superQiErc20Impl,superTokenInterface){
        if (lendingSwitch == 0){
            superAaveTokenImpl.onCompound();
        }else{
            superQiErc20Impl.onCompound();
        }
    }
}