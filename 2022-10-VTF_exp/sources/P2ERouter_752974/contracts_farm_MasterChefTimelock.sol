// SPDX-License-Identifier: MIT

pragma solidity >=0.6.12;

import '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import '../core/Timelock.sol';
import './MasterChef.sol';
import 'hardhat/console.sol';

contract MasterChefTimelock is Timelock {

    mapping(address => bool) public existsPools;
    mapping(address => uint) public pidOfPool;
    mapping(uint256 => bool) public isExcludedPidUpdate;
    MasterChef masterChef;

    struct SetPendingOwnerData {
        address pendingOwner;
        uint timestamp;
        bool exists;
    }
    SetPendingOwnerData setPendingOwnerData;

    constructor(MasterChef masterChef_, address admin_, uint delay_) Timelock(admin_, delay_) {
        require(address(masterChef_) != address(0), "illegal masterChef address");
        require(admin_ != address(0), "illegal admin address");
        masterChef = masterChef_;
    }

    modifier onlyAdmin() {
        require(msg.sender == admin, "Timelock::cancelTransaction: Call must come from admin.");
        _;
    }

    function excludedPidUpdate(uint256 _pid) external onlyAdmin{
        isExcludedPidUpdate[_pid] = true;
    }
    
    function includePidUpdate(uint256 _pid) external onlyAdmin{
        isExcludedPidUpdate[_pid] = false;
    }
    

    function addExistsPools(address pool, uint pid) external onlyAdmin {
        require(existsPools[pool] == false, "Timelock:: pair already exists");
        existsPools[pool] = true;
        pidOfPool[pool] = pid;
    }

    function delExistsPools(address pool) external onlyAdmin {
        require(existsPools[pool] == true, "Timelock:: pair not exists");
        delete existsPools[pool];
        delete pidOfPool[pool];
    }

    function add(uint256 _allocPoint, IERC20 _lpToken, bool _withUpdate) external onlyAdmin {
        require(address(_lpToken) != address(0), "_lpToken address cannot be 0");
        require(existsPools[address(_lpToken)] == false, "Timelock:: pair already exists");
        _lpToken.balanceOf(msg.sender); //check if is a legal pair
        uint pid = masterChef.poolLength();
        masterChef.add(_allocPoint, _lpToken, false);
        if(_withUpdate){
            massUpdatePools();
        }
        pidOfPool[address(_lpToken)] = pid;
        existsPools[address(_lpToken)] = true;
    }

    function set(uint256 _pid, uint256 _allocPoint, bool _withUpdate) external onlyAdmin {
        require(_pid < masterChef.poolLength(), 'Pool does not exist');

        masterChef.set(_pid, _allocPoint, false);
        if(_withUpdate){
            massUpdatePools();
        }
    }

    function massUpdatePools() public {
        uint256 length = masterChef.poolLength();
        for (uint256 pid = 0; pid < length; ++pid) {
            if(!isExcludedPidUpdate[pid]){
                masterChef.updatePool(pid);
            }
        }
    }
}
