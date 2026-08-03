// SPDX-License-Identifier: MIT
pragma solidity 0.8.22;

import {State} from "../interface/IAbond.sol";

library Colors {

    error InvalidUser();
    error InvalidCumulativeRate();
    error InvalidEthBacked();
    error InsufficientBalance();
    error InvalidAmount();

    /**
     * @dev update the user abond data after credit
     * @param _fromState struct which contains, state of user abond before credit
     * @param _toState struct which contains, state of user abond after credit
     * @param _amount abond amount
     */
    function _credit(
        State memory _fromState,
        State memory _toState,
        uint128 _amount
    ) internal pure returns(State memory){

        // find the average cumulatie rate
        _toState.cumulativeRate = _calculateCumulativeRate(_amount, _toState.aBondBalance, _fromState.cumulativeRate, _toState.cumulativeRate);
        // find the eth backed
        _toState.ethBacked = _calculateEthBacked(_amount, _toState.aBondBalance, _fromState.ethBacked, _toState.ethBacked);
        // increment abond balance
        _toState.aBondBalance += _amount;

        return _toState;
    }

    /**
     * @dev update the user abond data after debit
     * @param _fromState struct which contains, state of user abond before debit
     * @param _amount abond amount
     */
    function _debit(
        State memory _fromState,
        uint128 _amount
    ) internal pure returns(State memory) {

        uint128 balance = _fromState.aBondBalance;
        
        // check user has sufficient balance
        require(balance >= _amount,"InsufficientBalance");
 
        // update user abond balance
        _fromState.aBondBalance = balance - _amount;

        // after debit, if abond balance is zero, update cr and eth backed as 0
        if(_fromState.aBondBalance == 0){
            _fromState.cumulativeRate = 0;
            _fromState.ethBacked = 0;
        }
        return _fromState;
    }

    /**
     * @dev calculate cumulative rate for abond
     * @param _balanceA abond balance of user A or same user with previous abond balance 
     * @param _balanceB abond balance of user B or same user with new abond balance 
     * @param _crA cumulative rate of user A or same user with previous cr 
     * @param _crB cumulative rate of user B or same user with new cr
     */
    function _calculateCumulativeRate(uint128 _balanceA, uint128 _balanceB, uint256 _crA, uint256 _crB) internal pure returns(uint256){
        // If balance A is zero revert
        if (_balanceA == 0) revert InsufficientBalance();
        uint256 currentCumulativeRate;
        currentCumulativeRate = ((_balanceA * _crA)+(_balanceB * _crB))/(_balanceA + _balanceB); 
        return currentCumulativeRate;
    }

    /**
     * @dev calculates eth backed
     * @param _balanceA abond balance of user A or same user with previous abond balance 
     * @param _balanceB abond balance of user B or same user with new abond balance  
     * @param _ethBackedA eth backed of user A or same user with previous eth backed 
     * @param _ethBackedB eth backed of user B or same user with new eth backed
     */
    function _calculateEthBacked(uint128 _balanceA, uint128 _balanceB, uint128 _ethBackedA, uint128 _ethBackedB) internal pure returns(uint128){
        // If balance A is zero revert
        if (_balanceA == 0) revert InsufficientBalance();
        uint128 currentEthBacked;
        currentEthBacked = ((_balanceA * _ethBackedA)+(_balanceB * _ethBackedB))/(_balanceA + _balanceB); 
        return currentEthBacked;
    }
}
