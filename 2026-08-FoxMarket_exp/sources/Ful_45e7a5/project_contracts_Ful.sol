// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

interface IPancakePair {
  function sync() external;
}

contract Ful is ERC20, Ownable {

    uint256 public constant BASE_100 = 10000;

    address public governance;

    address public targetPool;    
    uint256 public targetRatio = 50;
    
    uint256 public sellRatio1 = 300; 
    uint256 public sellRatio2 = 200; 
    
    address public feeReceiver1;    
    address public feeReceiver2;    

    uint256 public lastBalanceTime;   

    mapping(address => bool) public whitelist; 
   
    // Errors
    error InvalidAddress();
    error Disabled();

    // Events
    event WhitelistAdded(address _address);
    event WhitelistRemoved(address _address);
    event BalancePoolBurned(uint256 _burnAmount);

    constructor(string memory _name, string memory _symbol, address _feeReceiver1, address _feeReceiver2, address _governance, uint256 _mintAmount) ERC20(_name, _symbol) Ownable(msg.sender) {
        feeReceiver1 = _feeReceiver1;
        feeReceiver2 = _feeReceiver2;
        governance = _governance;

        whitelist[msg.sender] = true;
        
        if(_mintAmount > 0){    
            _mint(msg.sender, _mintAmount * (10**decimals()));
        }
    }

   
    modifier onlyGovernance() {
        require(msg.sender == governance, "unauthorized access");
        _;
    }

  
    function _update(address _from, address _to, uint256 _amount) internal  override {
        if (_to == targetPool) { 
            if(!whitelist[_from]){
                // Transfer to pool (sell): apply sell tax
                uint256 sellfeeAmount1 = _amount * sellRatio1 / BASE_100;
                uint256 sellfeeAmount2 = _amount * sellRatio2 / BASE_100;

                if (sellfeeAmount1 > 0) {
                    super._update(_from, feeReceiver1, sellfeeAmount1);
                    _amount -= sellfeeAmount1;
                }
                if (sellfeeAmount2 > 0) {
                    super._update(_from, feeReceiver2, sellfeeAmount2);
                    _amount -= sellfeeAmount2;
                }
            }            
        }else if(_from == targetPool){
            if(!whitelist[_to]){
                revert Disabled();
            }
        }
        super._update(_from, _to, _amount);
    }
   

    function addWhitelist(address _addr) external onlyOwner {
        whitelist[_addr] = true;

        emit WhitelistAdded(_addr);
    }

  
    function removeWhitelist(address _addr) external onlyOwner {
        whitelist[_addr] = false;

        emit WhitelistRemoved(_addr);
    }

    function setTargetPool(address _newPool) external onlyOwner {
        if(_newPool == address(0)) revert InvalidAddress();
        targetPool =_newPool;
    }

    function transferGovernance(address _newGovernance) external onlyOwner {
        if (_newGovernance == address(0)) revert InvalidAddress();
        governance = _newGovernance;
    }
    
    function setFeeReceiver(address _newReceiver1, address _newReceiver2) external onlyGovernance {
        if (_newReceiver1 == address(0) || _newReceiver2 == address(0)) revert InvalidAddress();
        feeReceiver1 = _newReceiver1;
        feeReceiver2 = _newReceiver2;
    }
   
    function balancePool() external onlyGovernance {
        uint256 today = block.timestamp / 1 days * 1 days;
        require(today > lastBalanceTime, "cooldown");
        lastBalanceTime = today;

        uint256 burnAmount = balanceOf(targetPool) * targetRatio / BASE_100;
        _burn(targetPool, burnAmount);
       
        IPancakePair(targetPool).sync();
        
        emit BalancePoolBurned(burnAmount);
    }

    function burn(uint256 value) external {
        _burn(msg.sender, value);
    }
}