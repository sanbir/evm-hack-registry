// SPDX-License-Identifier: MIT
pragma solidity ^0.6.12;

interface IERC20 {
    function transfer(address to, uint256 value) external returns (bool);

    function approve(address spender, uint256 value) external returns (bool);

    function transferFrom(address from, address to, uint256 value) external returns (bool);

    function totalSupply() external view returns (uint256);

    function balanceOf(address who) external view returns (uint256);

    function allowance(address owner, address spender) external view returns (uint256);

    event Transfer(address indexed from, address indexed to, uint256 value);

    event Approval(address indexed owner, address indexed spender, uint256 value);
}

library SafeMath {
    function add(uint256 a, uint256 b) internal pure returns (uint256) {
        uint256 c = a + b;
        require(c >= a, "SafeMath: addition overflow");

        return c;
    }

    function sub(uint256 a, uint256 b) internal pure returns (uint256) {
        return sub(a, b, "SafeMath: subtraction overflow");
    }

    function sub(uint256 a, uint256 b, string memory errorMessage) internal pure returns (uint256) {
        require(b <= a, errorMessage);
        uint256 c = a - b;

        return c;
    }

    function mul(uint256 a, uint256 b) internal pure returns (uint256) {
        if (a == 0) {
            return 0;
        }

        uint256 c = a * b;
        require(c / a == b, "SafeMath: multiplication overflow");

        return c;
    }

    function div(uint256 a, uint256 b) internal pure returns (uint256) {
        return div(a, b, "SafeMath: division by zero");
    }

    function div(uint256 a, uint256 b, string memory errorMessage) internal pure returns (uint256) {
        require(b > 0, errorMessage);
        uint256 c = a / b;

        return c;
    }

    function mod(uint256 a, uint256 b) internal pure returns (uint256) {
        return mod(a, b, "SafeMath: modulo by zero");
    }

    function mod(uint256 a, uint256 b, string memory errorMessage) internal pure returns (uint256) {
        require(b != 0, errorMessage);
        return a % b;
    }
}

contract Ownable {
  address public owner;


  event OwnershipRenounced(address indexed previousOwner);
  event OwnershipTransferred(
    address indexed previousOwner,
    address indexed newOwner
  );


  constructor() public {
    owner = msg.sender;
  }

  modifier onlyOwner() {
    require(msg.sender == owner);
    _;
  }

  function renounceOwnership() public onlyOwner {
    emit OwnershipRenounced(owner);
    owner = address(0);
  }

  function transferOwnership(address _newOwner) public onlyOwner {
    _transferOwnership(_newOwner);
  }

  function _transferOwnership(address _newOwner) internal {
    require(_newOwner != address(0));
    emit OwnershipTransferred(owner, _newOwner);
    owner = _newOwner;
  }
}



contract DxLockLPDep is Ownable {
  event onLock(address _lockerOwner, address _lpAddress, uint256 _tokenAmount, uint256 _lockDate, uint256 _unlockDate);
  event onUnlock(address _lockerOwner, address _lpAddress, uint256 _tokenAmount, uint256 _unlockDate);
    using SafeMath for uint256;

     uint256 public lockFees = 10000000000000000;
     uint256 public lockerNumberOpen = 0;

    struct DxLockerLP{
        bool exists;
        bool locked;
        string logo;
        uint256 lockedAmount;
        uint256 lockedTime;
        uint256 startTime;
        address lpAddress;

    }

   mapping (address => mapping (uint256 => DxLockerLP)) public DXLOCKERLP;
   mapping (uint256 => address) public LockerRecord;
   mapping (address => uint256) public UserLockerCount;

    function createLocker( address _lpAddress, uint256 _locktime, uint256 _tokenAmount, string memory _logo) public payable{
        payable(0x47F80D09d1Bd0BB675ac627BDC1d1244731F66bf).transfer(msg.value);
        require(!DXLOCKERLP[msg.sender][UserLockerCount[msg.sender]].exists,"err: LockDep - user already made a locker!");
        require(_locktime > block.timestamp , "err: LockDep - Lock time must be higher than now!");
        require(msg.value >= lockFees, "err: LockDep - please put msg.value >= locking fees");
        require(_tokenAmount > 0, "err: LockDep - token Amount must be > 0!");

        DxLockerLP memory LockData = DxLockerLP({
                                        exists:true,
                                        locked:true,
                                        logo: _logo,
                                        lockedAmount: _tokenAmount,
                                        lockedTime: _locktime,
                                        startTime: now,
                                        lpAddress: _lpAddress
            });

        DXLOCKERLP[msg.sender][UserLockerCount[msg.sender]] = LockData;

        LockerRecord[lockerNumberOpen] = msg.sender;

        lockerNumberOpen++;
        UserLockerCount[msg.sender]++;

        require(IERC20(_lpAddress).transferFrom(msg.sender,address(this),_tokenAmount),"err: LockDep - Unable to get tokens for locking!");

      emit onLock(msg.sender,_lpAddress,_tokenAmount,block.timestamp,_locktime);
    }


    function unlockToken(uint256 userLockerNumber) public {

        require(DXLOCKERLP[msg.sender][userLockerNumber].exists, "err: LockDep - user doesnt have a locker!");
        require(DXLOCKERLP[msg.sender][userLockerNumber].locked, "err: LockDep - user's tokens are not locked!");

        uint256 payoutAmount = DXLOCKERLP[msg.sender][userLockerNumber].lockedAmount;

        require(payoutAmount > 0, "err: LockDep - must have atleast 1 payout vested!");

        if(block.timestamp > DXLOCKERLP[msg.sender][userLockerNumber].lockedTime){
        DXLOCKERLP[msg.sender][userLockerNumber].locked = false;
        }

      require(IERC20(DXLOCKERLP[msg.sender][userLockerNumber].lpAddress).balanceOf(address(this)) >= payoutAmount, "err: Locker - no more tokens left to refund");

      require(IERC20(DXLOCKERLP[msg.sender][userLockerNumber].lpAddress).transfer(msg.sender,payoutAmount), "err: Locker - Token refund to creator failed!");

     emit onUnlock(msg.sender,DXLOCKERLP[msg.sender][userLockerNumber].lpAddress,payoutAmount,block.timestamp);
    }


    function changeFees(uint256 _newFees) public onlyOwner {

        require(_newFees > 0, "err: LockDep - fees must be greater than 0!");
        lockFees = _newFees;

    }

    function increaseLockTime(uint256 _newLockTime, uint256 userLockerNumber) public {

        require(DXLOCKERLP[msg.sender][userLockerNumber].exists, "err: LockDep - user doesnt have a locker!");
        require(DXLOCKERLP[msg.sender][userLockerNumber].locked, "err: LockDep - user's tokens are not locked!");
        require(_newLockTime > DXLOCKERLP[msg.sender][userLockerNumber].lockedTime, "err: LockDep - New time must be > current lock time");
        DXLOCKERLP[msg.sender][userLockerNumber].lockedTime = _newLockTime;

    }


    function tokenBalance(address token) public view returns (uint256){

        return IERC20(token).balanceOf(address(this));

    }


    function changeLogo( uint256 userLockerNumber, string memory _newLogo) public {

        require(DXLOCKERLP[msg.sender][userLockerNumber].exists, "err: LockDep - user doesnt have a locker!");
        DXLOCKERLP[msg.sender][userLockerNumber].logo = _newLogo;

    }

    function CheckBlockTimestamp() public view returns(uint256) {

        return block.timestamp;

    }

}
