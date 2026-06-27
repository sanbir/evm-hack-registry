// SPDX-License-Identifier: GPL-3.0-or-later

pragma solidity >=0.7.0 <0.8.0;
import "../../interfaces/ICToken.sol";
import "../../interfaces/IBenqiCompound.sol";
import "../../modules/safeErc20.sol";
import "../superTokenInterface.sol";
// superToken is the coolest vault in town. You come in with some token, and leave with more! The longer you stay, the more token you get.
//
// This contract handles swapping to and from superToken.
abstract contract superQiTokenImpl is superTokenInterface{
    using SafeERC20 for IERC20;
    using SafeMath for uint256;
    IBenqiCompound public compounder;
    rewardInfo[] public benqiRewardInfos;
    IERC20 public qiToken;
    constructor(address _lendingToken){
        qiToken = IERC20(_lendingToken);
        compounder = IBenqiCompound(ICErc20(address(qiToken)).comptroller());
        setBenqiRewardToken(0,0,false,0x8729438EB15e2C8B576fCc6AeCdA6A148776C0F5,1e17);//qi
        setBenqiRewardToken(1,1,false,address(0),1e15);//avax
    }
    function getAvailableBalance() internal virtual override view returns (uint256){
        return _getTotalAssets();
    }
    function getTotalAssets() internal virtual override view returns (uint256){
        return _getTotalAssets();
    }
    function _getTotalAssets() internal view returns (uint256){
        uint256 exchangeRate = ICErc20(address(qiToken)).exchangeRateStored();
        return exchangeRate.mul(qiToken.balanceOf(address(this)))/calDecimals;
    }
    function setBenqiRewardToken(uint256 index,uint8 _reward,bool _bClosed,address _rewardToken,uint256 _sellLimit)internal { 
        require(_rewardToken != address(qiToken), "reward token error!");
        _setReward(benqiRewardInfos,index,_reward,_bClosed,_rewardToken,_sellLimit);
    }
    function claimRewards() internal {
        uint nLen = benqiRewardInfos.length;
        for (uint i=0;i<nLen;i++){
            rewardInfo memory info = benqiRewardInfos[i];
            if(info.bClosed){
                return;
            }
            address[] memory qiTokens = new address[](1); 
            qiTokens[0] = address(qiToken);
            compounder.claimReward(info.rewardType,address(this),qiTokens);
            swapOnDex(info.rewardToken,info.sellLimit);
        }
    }
    function getMidText()internal virtual override returns(string memory,string memory){
        return ("Benqi ","qi");
    }
}