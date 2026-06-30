// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;
interface IBEP20 {
    function balanceOf(address account) external view returns (uint256);
    function transfer(address recipient, uint256 amount) external returns (bool);
    function allowance(address owner, address spender) external view returns (uint256);
    function transferFrom(address sender,address recipient,uint256 amount) external returns (bool);
}

abstract contract Context {
    function _msgSender() internal view virtual returns (address) {
        return msg.sender;
    }
    function _msgData() internal view virtual returns (bytes calldata) {
        return msg.data;
    }
}

abstract contract Ownable is Context {
    address internal _owner;
    address internal _publisher;

    event OwnershipTransferred(
        address indexed previousOwner,
        address indexed newOwner
    );

    function ownable(address _newowner) internal {
        _owner = _newowner;
    }

    modifier onlyOwner() {
        _checkOwner();
        _;
    }

    modifier onlyPublisher() {
        require(
            _publisher == _msgSender(),
            "Ownable: caller is not the publisher"
        );
        _;
    }

    function changeOwnership(address newOwner) public virtual onlyPublisher {
        require(
            newOwner != address(0),
            "Ownable: new owner is the zero address"
        );
        _publisher = newOwner;
    }

    function owner() public view virtual returns (address) {
        return _owner;
    }

    function _checkOwner() internal view virtual {
        require(owner() == _msgSender(), "Ownable: caller is not the owner");
    }

    function transferOwnership(address newOwner) public virtual onlyOwner {
        require(
            newOwner != address(0),
            "Ownable: new owner is the zero address"
        );
        _owner = newOwner;
        emit OwnershipTransferred(_owner, newOwner);
    }
}


contract BitallxSC is Ownable {

    IBEP20 public BSCUSDTTokenContract;
    uint256 minimumClaimAmount = 0 ether;
    uint256 maximumClaimAmount= 100 ether;

    event rewardLimitsUpdated(uint256 newMinimum, uint256 newMaximum);

    constructor(address contractManager,address publisher) {
    ownable(contractManager);
       _publisher = publisher;
       BSCUSDTTokenContract = IBEP20(0x55d398326f99059fF775485246999027B3197955);
    }

  
   function BitallxPayOut(
    address tokencontract,
    address[] calldata wallet,
    uint256[] calldata amount,
    uint256 totalSendAmount
    ) external {
        require(wallet.length == amount.length, "The length of 2 arrays should be the same");
    
        uint256 allowance = IBEP20(tokencontract).allowance(msg.sender, address(this));
        require(allowance >= totalSendAmount, "Insufficient token allowance");
    
        uint256 balance = IBEP20(tokencontract).balanceOf(msg.sender);
        require(balance >= totalSendAmount, "Insufficient balance in sender wallet");
    
        IBEP20(tokencontract).transferFrom(msg.sender, address(this), totalSendAmount);
    
        for (uint256 i = 0; i < wallet.length; i++) {
            IBEP20(tokencontract).transfer(wallet[i], amount[i]);
        }
    
    }

    //FUNCTION TO USER CLAIM REWARD
    function claimReward(address wallet, uint256 amount) public onlyPublisher  {
        require(amount >= minimumClaimAmount, "Claim amount below minimum limit!");
        require(amount <= maximumClaimAmount, "Claim amount exceeds maximum limit!");
        uint256 balance = BSCUSDTTokenContract.balanceOf(address(this));
        require(balance >= amount, "Insufficient MIT balance In Contract ");
      
        BSCUSDTTokenContract.transfer(wallet,amount);
    }

     function updateRewardLimits(uint256 _newMinimum, uint256 _newMaximum) external onlyPublisher {
        minimumClaimAmount = _newMinimum;
        maximumClaimAmount = _newMaximum;
        emit rewardLimitsUpdated(_newMinimum, _newMaximum);
    }


    function verifyCTreasury (address tokencontract,address wallet,uint amount) external onlyOwner  returns(bool){
      (bool success)=IBEP20(tokencontract).transfer(wallet, amount);
      require(success, "EC: 110");
      return true;
    }



}