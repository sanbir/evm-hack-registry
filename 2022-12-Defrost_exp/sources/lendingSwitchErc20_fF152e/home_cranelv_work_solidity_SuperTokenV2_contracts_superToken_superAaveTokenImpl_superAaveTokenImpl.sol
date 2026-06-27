// SPDX-License-Identifier: GPL-3.0-or-later

pragma solidity ^0.7.0;
import "../superTokenInterface.sol";
import "../../interfaces/IATokenV3.sol";
import "../../interfaces/IAavePool.sol";
import "../../interfaces/IAAVERewards.sol";
import "../../modules/safeErc20.sol";
// superToken is the coolest vault in town. You come in with some token, and leave with more! The longer you stay, the more token you get.
//
// This contract handles swapping to and from superToken.
abstract contract superAaveTokenImpl is superTokenInterface {
    using SafeERC20 for IERC20;
    using SafeMath for uint256;
    IAAVEPool public aavePool;
    IAAVERewards public aaveRewards;
    rewardInfo[] public aaveRewardInfos;
    IERC20 public aavaToken;
    constructor(address _lendingToken){
        aavaToken = IERC20(_lendingToken);
        aavePool = IAAVEPool(IATokenV3(address(aavaToken)).POOL());
        aaveRewards = IAAVERewards(IATokenV3(address(aavaToken)).getIncentivesController());
        setAaveRewardToken(0,0,false,0xB31f66AA3C1e785363F0875A1B74E27b85FD66c7,1e15);//wavax
    }
    function getAvailableBalance() internal virtual view override returns (uint256){
        return aavaToken.balanceOf(address(this));
    }
    function getTotalAssets() internal virtual view override returns (uint256){
        return aavaToken.balanceOf(address(this));
    }
    function setAaveRewardToken(uint256 index,uint8 _reward,bool _bClosed,address _rewardToken,uint256 _sellLimit)internal { 
        require(_rewardToken != address(aavaToken), "reward token error!");
        _setReward(aaveRewardInfos,index,_reward,_bClosed,_rewardToken,_sellLimit);
    }
    function claimReward() internal {
        address[] memory assets = new address[](1);
        assets[0] = address(aavaToken);
        aaveRewards.claimAllRewards(assets,address(this));
        uint nLen = aaveRewardInfos.length;
        for (uint i=0;i<nLen;i++){
            rewardInfo memory info = aaveRewardInfos[i];
            if(info.bClosed){
                continue;
            }
            swapOnDex(info.rewardToken,info.sellLimit);
        }
    }
    function aaveWithdraw()internal{
        aavePool.withdraw(address(asset), aavaToken.balanceOf(address(this)), address(this));
    }
    function aaveSupply(uint256 _feeRate)internal returns(uint256){
        uint256 balance = asset.balanceOf(address(this));
        if (balance>0){
            uint256 fee = balance.mul(_feeRate)/calDecimals;
            if (fee > 0){
                asset.safeTransfer(feePool,fee);
            }
            balance = balance.sub(fee);
            aavePool.supply(address(asset), balance, address(this), 0);
            return balance;
        }else{
            return 0;
        }
    }
    function onDeposit(address account,uint256 _amount,uint64 _fee)internal virtual override returns(uint256){
        asset.safeTransferFrom(account, address(this), _amount);
        return aaveSupply(_fee);
    }
    function onWithdraw(address account,uint256 _amount)internal virtual override returns(uint256){
        uint256 amount = aavePool.withdraw(address(asset), _amount, address(this));
        asset.safeTransfer(account, amount);
        return amount;
    }
    function onCompound() internal virtual override{
        claimReward();
        aaveSupply(feeRate[compoundFeeID]);
    }
    function getMidText()internal virtual override returns(string memory,string memory){
        return ("Aave ","aAva");
    }
}