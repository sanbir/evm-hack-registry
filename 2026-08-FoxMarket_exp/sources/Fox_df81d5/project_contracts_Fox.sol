// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";


contract Fox is ERC20, Ownable {

    address public governance;
    
    address public treasury;
    
    mapping(address => bool) public whitelist; 

    address public targetPool;

    bool public transferStatus;
    
    uint256 public sellRatio = 250; 
    
    address public feeReceiver;
    
    uint256 public constant BASE_100 = 10000;
   
    // Errors
    error InvalidAddress();
    error Disabled();

    // Events
    event GovernanceAddressUpdated(address _newGovernance);
    event TreasuryAddressUpdated(address _newTreasury);
    event FeeReceiverAddressUpdated(address _newReceiver);
    event SellRateChanged(uint256 _ratio);
    event BalancePoolAddressUpdated(address _pool);
    event TokenTransferStateUpdated(bool _enabled);
    event WhitelistAdded(address _address);
    event WhitelistRemoved(address _address);

    
    constructor(string memory _name, string memory _symbol, address _feeReceiver, address _governance, uint256 _mintAmount) ERC20(_name, _symbol) Ownable(msg.sender) {
        feeReceiver = _feeReceiver;
        governance = _governance;

        whitelist[msg.sender] = true;
        _mint(msg.sender, _mintAmount * (10**decimals()));
    }

    
    modifier onlyGovernance() {
        require(msg.sender == governance, "unauthorized access");
        _;
    }

    function _update(address _from, address _to, uint256 _amount) internal  override {
        if(!transferStatus){
            if(!whitelist[_from] && !whitelist[_to]){
                revert Disabled();
            }
        }else{
            if (_to == targetPool  && !whitelist[_from]) { 
                // Transfer to pool (sell): apply sell tax
                uint256 sellfeeAmount = _amount * sellRatio / BASE_100;
                if (sellfeeAmount > 0) {
                    super._update(_from, feeReceiver, sellfeeAmount);
                    _amount -= sellfeeAmount;
                }
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

        emit BalancePoolAddressUpdated(targetPool);
    }

    function setTreasury(address _newTreasury) external onlyOwner {
        require(_newTreasury != address(0), "Invalid address");
        treasury = _newTreasury;

        emit TreasuryAddressUpdated(treasury);
    }
   
    function setTransferState(bool _enable) external onlyOwner {
        transferStatus = _enable;

        emit TokenTransferStateUpdated(_enable);
    }
  
    function transferGovernance(address _newGovernance) external onlyOwner {
        if(_newGovernance == address(0)) revert InvalidAddress();
        governance = _newGovernance;

        emit GovernanceAddressUpdated(governance);
    }

    function setFeeReceiver(address _newReceiver) external onlyGovernance {
        require(_newReceiver != address(0), "Invalid address");
        feeReceiver = _newReceiver;

        emit FeeReceiverAddressUpdated(feeReceiver);
    }

    function setSellRates(uint256 _newTaxRate) external onlyGovernance {
        require(_newTaxRate >= 250 && _newTaxRate <= 3000, "Invalid ratio");
        sellRatio = _newTaxRate;

        emit SellRateChanged(sellRatio);
    }
   
    function mint(address _to, uint256 _amount) external {
        require(msg.sender == treasury, "Unauthorized");

        _mint(_to, _amount);
    }

    function burn(uint256 value) external {
        _burn(msg.sender, value);
    }
}