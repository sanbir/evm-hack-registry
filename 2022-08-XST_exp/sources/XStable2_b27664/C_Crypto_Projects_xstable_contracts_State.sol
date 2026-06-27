// SPDX-License-Identifier: MIT

pragma solidity ^0.6.12;
pragma experimental ABIEncoderV2;

contract State {

    mapping (address => uint256) _largeBalances;
    mapping (address => mapping (address => uint256)) _allowances;

    // Supported pools and data for measuring mint & burn factors
    struct PoolCounter {
        address pairToken;
        uint256 tokenBalance;
        uint256 pairTokenBalance;
        uint256 lpBalance;
        uint256 startTokenBalance;
        uint256 startPairTokenBalance;
    }
    address[] _supportedPools;
    mapping (address => PoolCounter) _poolCounters;
    mapping (address => bool) _isSupportedPool;
    address _mainPool;

    uint256 _currentEpoch;
    
    //Creating locked balances
    struct LockBox {
        address beneficiary;
        uint256 lockedBalance;
        uint256 unlockTime;
        bool locked;
    }
    LockBox[] _lockBoxes;
    mapping(address => uint256) _lockedBalance;
    mapping(address => bool) _hasLockedBalance;
    uint256 _totalLockedBalance;
 
    uint256 _largeTotal;
    uint256 _totalSupply;

    address _liquidityReserve;
    address _stabilizer;

    bool _presaleDone;
    address _presaleCon;
    
    bool _paused;
    
    bool _taxLess;
    mapping(address=>bool) _isTaxlessSetter;
}