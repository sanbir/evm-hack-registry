// SPDX-License-Identifier: GPL-3.0-or-later

pragma solidity >=0.7.0 <0.8.0;

import "./superTokenInterface.sol";
import "../modules/IERC20.sol";
import "../modules/safeErc20.sol";
import "../modules/proxyOwner.sol";
import "../interfaces/IERC3156FlashBorrower.sol";
import "../modules/ReentrancyGuard.sol";
import "../modules/timeLockSetting.sol";
// superToken is the coolest vault in town. You come in with some token, and leave with more! The longer you stay, the more token you get.
//
// This contract handles swapping to and from superToken.
abstract contract baseSuperToken is timeLockSetting,superTokenInterface,proxyOwner,ReentrancyGuard{
    using SafeERC20 for IERC20;
    using SafeMath for uint256;
    bytes32 private constant _RETURN_VALUE = keccak256("ERC3156FlashBorrower.onFlashLoan");
    uint256 public latestCompoundTime;

    event Compound(address indexed sender);
    event FlashLoan(address indexed sender,address indexed receiver,address indexed token,uint256 amount);
    event SetFeePoolAddress(address indexed sender,address _feePool);
    event SetSlipRate(address indexed sender,uint256 _slipRate);
    event SetFeeRate(address indexed sender,uint256 index,uint256 _feeRate);
    // Define the baseSuperToken token contract
    constructor(address multiSignature,address origin0,address origin1,
        address payable _swapHelper,address payable _feePool)
        proxyOwner(multiSignature,origin0,origin1) {
        feePool = _feePool;
        swapHelper = ISwapHelper(_swapHelper);
        WAVAX = IWAVAX(swapHelper.WAVAX());
        feeRate[compoundFeeID] = 2e17;
        feeRate[enterFeeID] = 0;
        feeRate[flashFeeID] = 1e14;
    }
    function getRate()external view returns(uint256){
        // Gets the amount of superToken in existence
        uint256 totalShares = totalSupply();
        // Calculates the amount of stakeToken the superToken is worth
        if (totalShares>0){
            return getTotalAssets().mul(calDecimals)/totalShares;
        }
        return calDecimals;
    }
    // Enter the bar. Pay some stakeTokens. Earn some shares.
    // Locks stakeToken and mints superToken
    function deposit(uint256 _amount, address receiver) external returns (uint256){
        uint256 amount = _deposit(msg.sender,_amount,receiver);
        emit Deposit(msg.sender,receiver,_amount,amount);
        return amount;
    }
    // Burns _share from owner and sends exactly _value of asset tokens to receiver.
    function withdraw(uint256 _value,address receiver,address owner) external returns (uint256) {
        uint256 _share = convertToShares(_value);
        _withdraw(_value,_share,receiver,owner);
        emit Withdraw(msg.sender,receiver,_value,_share);
        return _share;
    }

    // Burns exactly shares from owner and sends assets of asset tokens to receiver.
    function redeem(uint256 shares,address receiver,address owner) external returns (uint256) {
        uint256 _value = convertToAssets(shares);
        _withdraw(_value,shares,receiver,owner);
        emit Withdraw(msg.sender,receiver,_value,shares);
        return _value;
    }
    //The amount of shares that the Vault would exchange for the amount of assets provided, in an ideal scenario where all the conditions are met.
    function convertToShares(uint256 _assetNum) public view returns(uint256){
        return _assetNum.mul(totalSupply())/getTotalAssets();
    }
    //The amount of assets that the Vault would exchange for the amount of shares provided, in an ideal scenario where all the conditions are met.
    function convertToAssets(uint256 _shareNum) public view returns(uint256){
        return _shareNum.mul(getTotalAssets())/totalSupply();
    }
    function _withdraw(uint256 _assetNum,uint256 _shareNum,address receiver,address owner) internal {
        require(msg.sender == owner,"owner must be msg.sender!");
        require(_shareNum>0,"super token burn 0!");
        _burn(msg.sender, _shareNum);
        _assetNum = onWithdraw(receiver, _assetNum);
    }
    function _deposit(address from,uint256 _amount, address receiver) internal returns (uint256){
        // Gets the amount of stakeToken locked in the contract
        uint256 totaStake = getTotalAssets();
        // Gets the amount of superToken in existence
        uint256 totalShares = totalSupply();
        _amount = onDeposit(from,_amount,feeRate[enterFeeID]);
        // If no superToken exists, mint it 1:1 to the amount put in
        if (totalShares == 0 || totaStake == 0) {
            _mint(receiver, _amount);
            return _amount;
        }
        // Calculate and mint the amount of superToken the stakeToken is worth. The ratio will change overtime, as superToken is burned/minted and stakeToken deposited + gained from fees / withdrawn.
        else {
            uint256 what = _amount.mul(totalShares)/totaStake;
            require(what>0,"super token mint 0!");
            _mint(receiver, what);
            return what;
        }
    }
    function depositETH(address receiver)external payable AVAXUnderlying nonReentrant returns(uint256){
        WAVAX.deposit{value: msg.value}();
        uint256 amount = _deposit(address(this),msg.value,receiver);
        emit Deposit(msg.sender,receiver,msg.value,amount);
        return amount;
    }
    function withdrawETH(uint256 _value,address receiver,address owner) external AVAXUnderlying nonReentrant returns (uint256) {
        uint256 _share = convertToShares(_value);
        _withdraw(_value,_share,address(this),owner);
        WAVAX.withdraw(_value);
        _safeTransferETH(receiver, _value);
        emit Withdraw(msg.sender,receiver,_value,_share);
        return _share;
    }
    function redeemETH(uint256 shares,address receiver,address owner) external AVAXUnderlying nonReentrant returns (uint256) {
        uint256 _value = convertToAssets(shares);
        _withdraw(_value,shares,address(this),owner);
        WAVAX.withdraw(_value);
        _safeTransferETH(receiver, _value);
        emit Withdraw(msg.sender,receiver,_value,shares);
        return _value;
    }
    function totalAssets()external view returns(uint256){
        return getTotalAssets();
    }
    function compound() external {
        latestCompoundTime = block.timestamp;
        onCompound();
        emit Compound(msg.sender);
    }
    function setFeePoolAddress(address payable feeAddress)external onlyOrigin notZeroAddress(feeAddress){
        feePool = feeAddress;
        emit SetFeePoolAddress(msg.sender,feeAddress);
    }
    function setSlipRate(uint256 _slipRate) external onlyOrigin{
        require(_slipRate < 1e18,"slipRate out of range!");
        slipRate = _slipRate;
        emit SetSlipRate(msg.sender,_slipRate);
    }
    function setFeeRate(uint256 index,uint64 _feeRate) external onlyOrigin{
        require(_feeRate < 5e17,"feeRate out of range!");
        feeRate[index] = _feeRate;
        emit SetFeeRate(msg.sender,index,_feeRate);
    }
    
    function setSwapHelper(address _swapHelper) external onlyOrigin notZeroAddress(_swapHelper) {
        require(_swapHelper != address(swapHelper),"SwapHelper set error!");
        _set(1,uint256(_swapHelper));
    }
    function acceptSwapHelper() external onlyOrigin {
        swapHelper = ISwapHelper(address(_accept(1)));
    }

    function maxFlashLoan(address token) external view returns (uint256){
        require(token == address(asset),"flash borrow token Error!");
        return getAvailableBalance();
    }
    function flashFee(address token, uint256 amount) public view virtual returns (uint256) {
        // silence warning about unused variable without the addition of bytecode.
        require(token == address(asset),"flash borrow token Error!");
        return amount.mul(feeRate[flashFeeID])/calDecimals;
    }
    modifier AVAXUnderlying() {
        require(address(asset) == address(WAVAX), "Not WAVAX super token");
        _;
    }
    function flashLoan(
        IERC3156FlashBorrower receiver,
        address token,
        uint256 amount,
        bytes calldata data
    ) external virtual returns (bool) {
        require(token == address(asset),"flash borrow token Error!");
        uint256 fee = flashFee(token, amount);
        onWithdraw(address(receiver),amount);
        require(
            receiver.onFlashLoan(msg.sender, token, amount, fee, data) == _RETURN_VALUE,
            "invalid return value"
        );
        onDeposit(address(receiver),amount + fee,0);
        emit FlashLoan(msg.sender,address(receiver),token,amount);
        return true;
    }
}