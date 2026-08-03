// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import '../interfaces/IERC20.sol';
import '../libraries/SafeMath.sol';
import './dSoulBound.sol';

/// @notice Mute DAO token, untransferrable
contract dMute is dSoulBound {
    using SafeMath for uint;

    address public MuteToken;

    struct UserLockInfo {
      uint256 amount;
      uint256 time;
      uint256 tokens_minted;
    }

    mapping(address => UserLockInfo[]) public _userLocks;

    uint private unlocked = 1;

    event LockEvent(address to, uint256 lockAmount, uint256 mintedAmount, uint256 totalTime);
    event RedeemEvent(address to, uint256 unlockedAmount, uint256 burnAmount);

    modifier nonReentrant() {
        require(unlocked == 1, 'dMute::ReentrancyGuard: REENTRANT_CALL');
        unlocked = 0;
        _;
        unlocked = 1;
    }

    /// @dev Expects a LP token address & the base reward muteToken address
    constructor (address _muteToken) {
        require(_muteToken != address(0), "MuteAmplifier: invalid muteToken");
        MuteToken = _muteToken;
    }

    /*
    function lockBonus(uint256 lock_time) internal view returns (uint256){
        uint256 week_time = 60 * 60 * 24 * 7;
        uint256 max_lock = week_time.mul(52 * 2); // 2 years

        return lock_time.mul(10**18).div(max_lock).mul(10);
    }
    */

    function timeToTokens(uint256 _amount, uint256 _lock_time) internal pure returns (uint256){
        uint256 week_time = 1 weeks;
        uint256 max_lock = 52 weeks;

        require(_lock_time >= week_time, "dMute::Lock: INSUFFICIENT_TIME_PARAM");
        require(_lock_time <= max_lock, "dMute::Lock: INSUFFICIENT_TIME_PARAM");

        // amount * % of time locked up from min to max
        uint256 base_tokens = _amount.mul(_lock_time.mul(10**18).div(max_lock)).div(10**18);
        // apply % min max bonus
        //uint256 boosted_tokens = base_tokens.mul(lockBonus(lock_time)).div(10**18);

        return base_tokens;
    }

    function Lock(uint256 _amount, uint256 _lock_time) public {
        LockTo(_amount, _lock_time, msg.sender);
    }

    function LockTo(uint256 _amount, uint256 _lock_time, address to) public nonReentrant {
        require(IERC20(MuteToken).balanceOf(msg.sender) >= _amount, "dMute::Lock: INSUFFICIENT_BALANCE");

        //transfer tokens to this contract
        IERC20(MuteToken).transferFrom(msg.sender, address(this), _amount);

        // calculate dTokens to mint
        uint256 tokens_to_mint = timeToTokens(_amount, _lock_time);

        require(tokens_to_mint > 0, 'dMute::Lock: INSUFFICIENT_TOKENS_MINTED');

        _mint(to, tokens_to_mint);

        _userLocks[to].push(UserLockInfo(_amount, block.timestamp.add(_lock_time), tokens_to_mint));

        emit LockEvent(to, _amount, tokens_to_mint, _lock_time);
    }

    function Redeem(uint256[] memory lock_index) public {
        RedeemTo(lock_index, msg.sender);
    }

    function RedeemTo(uint256[] memory lock_index, address to) public nonReentrant {
        uint256 total_to_redeem = 0;
        uint256 total_to_burn = 0;

        for(uint256 i; i < lock_index.length; i++){
          uint256 index = lock_index[i];
          UserLockInfo memory lock_info = _userLocks[msg.sender][index];

          require(block.timestamp >= lock_info.time, "dMute::Redeem: INSUFFICIENT_LOCK_TIME");
          require(lock_info.amount >= 0 , "dMute::Redeem: INSUFFICIENT_AMOUNT");
          require(lock_info.tokens_minted >= 0 , "dMute::Redeem: INSUFFICIENT_MINT_AMOUNT");

          total_to_redeem = total_to_redeem.add(lock_info.amount);
          total_to_burn = total_to_burn.add(lock_info.tokens_minted);

          _userLocks[msg.sender][index] = UserLockInfo(0,0,0);
        }

        require(total_to_redeem > 0, "dMute::Lock: INSUFFICIENT_REDEEM_AMOUNT");
        require(total_to_burn > 0, "dMute::Lock: INSUFFICIENT_BURN_AMOUNT");


        for(uint256 i = _userLocks[msg.sender].length; i > 0; i--){
          UserLockInfo memory lock_info = _userLocks[msg.sender][i - 1];

          // recently redeemed lock, destroy it
          if(lock_info.time == 0){
            _userLocks[msg.sender][i - 1] = _userLocks[msg.sender][_userLocks[msg.sender].length - 1];
            _userLocks[msg.sender].pop();
          }
        }

        //redeem tokens to user
        IERC20(MuteToken).transfer(to, total_to_redeem);
        //burn dMute
        _burn(msg.sender, total_to_burn);


        emit RedeemEvent(msg.sender, total_to_redeem, total_to_burn);
    }

    function GetUserLockLength(address account) public view returns (uint256 amount) {
        amount = _userLocks[account].length;
    }

    function GetUnderlyingTokens(address account) public view returns(uint256 amount) {
        for(uint256 i; i < _userLocks[account].length; i++){
          amount = amount.add(_userLocks[account][i].amount);
        }
    }
}
