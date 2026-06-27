// SPDX-License-Identifier: GPL-3.0-or-later

pragma solidity >=0.7.0 <0.8.0;
import "../modules/SafeMath.sol";
import "../modules/IERC20.sol";
import "../interfaces/IWAVAX.sol";
import "../swapHelper/ISwapHelper.sol";
import "../modules/safeErc20.sol";
import "../modules/ERC20.sol";
// superTokenInterface is the coolest vault in town. You come in with some token, and leave with more! The longer you stay, the more token you get.
//
// This contract handles swapping to and from superTokenInterface.
abstract contract superTokenInterface is ERC20{
    using SafeERC20 for IERC20;
    using Address for address;
    using SafeMath for uint256;
    uint256 constant calDecimals = 1e18;
    IERC20 public asset;
    ISwapHelper public swapHelper;
    IWAVAX public WAVAX;
    uint256 public slipRate = 98e16;

    address payable public feePool;
        struct rewardInfo {
        uint8 rewardType;
        bool bClosed;
        address rewardToken;
        uint256 sellLimit;
    }
    uint64[3] public feeRate;
    uint256 internal constant compoundFeeID = 0;
    uint256 internal constant enterFeeID = 1;
    uint256 internal constant flashFeeID = 2;
    /**
     * @dev `sender` has exchanged `assets` for `shares`, and transferred those `shares` to `receiver`.
     */
    event Deposit(address indexed sender, address indexed receiver, uint256 assets, uint256 shares);

    /**
     * @dev `sender` has exchanged `shares` for `assets`, and transferred those `assets` to `receiver`.
     */
    event Withdraw(address indexed sender, address indexed receiver, uint256 assets, uint256 shares);
    event LendTo(address indexed sender,address indexed account,uint256 amount);
    event RepayFrom(address indexed sender,address indexed account,uint256 amount);
    event SetReward(address indexed sender, uint256 index,uint8 _reward,bool _bClosed,address _rewardToken,uint256 _sellLimit);
    function onDeposit(address account,uint256 _amount,uint64 _fee)internal virtual returns(uint256);
    function onWithdraw(address account,uint256 _amount)internal virtual returns(uint256);
    function getAvailableBalance() internal virtual view returns (uint256);
    function onCompound() internal virtual;
    function getTotalAssets() internal virtual view returns (uint256);
    function getMidText()internal virtual returns(string memory,string memory);
    receive() external payable {
        // React to receiving ether
    }
    function setTokenInfo(string memory _prefixName,string memory _prefixSympol)internal{
        (string memory midName,string memory midSymbol) = getMidText();
        string memory tokenName_ = string(abi.encodePacked(_prefixName,midName,asset.name()));
        string memory symble_ = string(abi.encodePacked(_prefixSympol,midSymbol,asset.symbol()));
        setErc20Info(tokenName_,symble_,asset.decimals());
    }
    function availableBalance() external view returns (uint256){
        return getAvailableBalance();
    }
    function swapOnDex(address token,uint256 sellLimit)internal{
        uint256 balance = (token != address(0)) ? IERC20(token).balanceOf(address(this)) : address(this).balance;
        if (balance < sellLimit){
            return;
        }
        swapTokensOnDex(token,address(asset),balance);
    }
    function swapTokensOnDex(address token0,address token1,uint256 balance)internal{
        if(token0 == token1){
            return;
        }
        if (token0 == address(0)){
            WAVAX.deposit{value: balance}();
            token0 = address(WAVAX);
            if(token1 == address(WAVAX)){
                 return;
            }
        }else if(token0 == address(WAVAX) && token1 == address(0)){
            WAVAX.withdraw(balance);
            return;
        }
        approveRewardToken(token0);
        swapHelper.swapExactTokens_oracle(token0,token1,balance,slipRate,address(this));
    }
    function _safeTransferETH(address to, uint256 value) internal {
        (bool success, ) = to.call{value: value}(new bytes(0));
        require(success, 'ETH_TRANSFER_FAILED');
    }
    modifier notZeroAddress(address inputAddress) {
        require(inputAddress != address(0), "superToken : Zero Address");
        _;
    }
    function approveRewardToken(address token)internal {
        if(token != address(0) && IERC20(token).allowance(address(this), address(swapHelper)) == 0){
            SafeERC20.safeApprove(IERC20(token), address(swapHelper), uint(-1));
        }
    }
    function _setReward(rewardInfo[] storage rewardInfos,uint256 index,uint8 _reward,bool _bClosed,address _rewardToken,uint256 _sellLimit) internal virtual{
        if(index <rewardInfos.length){
            rewardInfo storage info = rewardInfos[index];
            info.rewardType = _reward;
            info.bClosed = _bClosed;
            info.rewardToken = _rewardToken;
            info.sellLimit = _sellLimit;
        }else{
            rewardInfos.push(rewardInfo(_reward,_bClosed,_rewardToken,_sellLimit));
        }
        emit SetReward(msg.sender,index,_reward,_bClosed,_rewardToken,_sellLimit);
    }
}