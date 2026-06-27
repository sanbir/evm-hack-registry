// SPDX-License-Identifier: GPL-3.0-or-later

pragma solidity >=0.7.0 <0.8.0;

import "./baseSuperToken.sol";
import "../modules/IERC20.sol";
import "../modules/SafeMath.sol";
import "../modules/safeErc20.sol";
import "../interestEngine/interestLinearEngineHash.sol";
import "./superTokenInterface.sol";
// superToken is the coolest vault in town. You come in with some token, and leave with more! The longer you stay, the more token you get.
//
// This contract handles swapping to and from superToken.
abstract contract lendingSuperToken is superTokenInterface,interestLinearEngineHash{
    using SafeERC20 for IERC20;
    using SafeMath for uint256;
    uint256 public interestFee = 5e14;
    address public immutable ownerLeverageFactory;
        // --- Auth ---
    mapping (address => uint256) public authorizedAccounts;
    event Borrow(address indexed sender,bytes32 indexed account,address indexed token,uint256 reply);
    event Repay(address indexed sender,bytes32 indexed account,address indexed token,uint256 amount);
    event SetInterestFee(address indexed sender,uint256 interestFee);
    event AddAuthorization(address account);
    event RemoveAuthorization(address account);
    event SetPoolLimitation(address indexed sender,uint256 assetCeiling,uint256 assetFloor);
    constructor(address leverageFactory,uint256 _assetFloor){
//        authorizedAccounts[leverageFactory] = 1;
        ownerLeverageFactory = leverageFactory;
        assetCeiling = uint(-1);
        assetFloor = _assetFloor;
        _setInterestInfo(23148148148148148148,1,1e30,1e27);
    } 
    function setPoolLimitation(uint256 _assetCeiling,uint256 _assetFloor)external isFactory{
        assetCeiling = _assetCeiling;
        assetFloor = _assetFloor;
        emit SetPoolLimitation(msg.sender,_assetCeiling,_assetFloor);
    }
    /**
     * @notice Add auth to an account
     * @param account Account to add auth to
     */
    function addAuthorization(address account) external isFactory notZeroAddress(account) {
        authorizedAccounts[account] = 1;
        emit AddAuthorization(account);
    }
    /**
     * @notice Remove auth from an account
     * @param account Account to remove auth from
     */
    function removeAuthorization(address account) external isFactory notZeroAddress(account) {
        authorizedAccounts[account] = 0;
        emit RemoveAuthorization(account);
    }
    /**
    * @notice Checks whether msg.sender can call an authed function
    **/
    modifier isAuthorized {
        require(authorizedAccounts[msg.sender] == 1, "leverageSuperToken : account is not authorized");
        _;
    }
    modifier isFactory {
        require(msg.sender == ownerLeverageFactory,"sender is not owner factory");
        _;
    }
    function setInterestFee(uint256 _interestFee) external isFactory {
        require(_interestFee<=5e17,"input interest rate is too large");
        interestFee = _interestFee;
        emit SetInterestFee(msg.sender,_interestFee);
    }
    function setInterestRate(int256 _interestRate,uint256 rateInterval)external isFactory{
        _setInterestInfo(_interestRate,rateInterval,1e30,1e27);
    }
    function totalLoan()external view returns(uint256){
        return totalAssetAmount();
    }
    function loan(bytes32 account) external view returns(uint256){
        return getAssetBalance(account);
    }
    function borrowLimit()external view returns (uint256){
        return getAvailableBalance();
    }
    function borrow(bytes32 account,uint256 amount) external isAuthorized {
        addAsset(account,amount);
        onWithdraw(msg.sender,amount);
        emit Borrow(msg.sender,account, address(asset),amount);
    }
    function repay(bytes32 account,uint256 amount) external payable isAuthorized {
        if (amount == uint(-1)){
            amount = getAssetBalance(account);
        }
        uint256 _repayDebt = subAsset(account,amount);
        if(amount>_repayDebt){
            uint256 fee = amount.sub(_repayDebt).mul(interestFee)/calDecimals;
            if (fee>0){
                asset.safeTransferFrom(msg.sender, feePool, fee);
            }
            amount = amount.sub(fee);
        }
        onDeposit(msg.sender,amount,0);
        emit Repay(msg.sender,account,address(asset),amount);
    }

}