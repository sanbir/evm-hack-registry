// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

interface IMintableERC20 {
    function mint(address to, uint256 amount) external;
}

interface IFoxTimeLockPool {
    function timeLock(uint256 _timeLockId, address _user, uint256 _amount) external;
    function rebase() external;
}

interface IFulTimeLockPool {
    function timeLock(uint256 _timeLockId, address _user, uint256 _amount) external;
    function rebase() external;
}

contract Treasury is Initializable, OwnableUpgradeable {
    using SafeERC20 for IERC20;

    address public constant DEAD = 0x000000000000000000000000000000000000dEaD;
    uint256 public constant BASE_100 = 10000;
    uint256 public constant REWARD_RATIO = 1100;

    address public governance;

    address public usdtToken;
    address public foxToken;
    address public stakedFoxToken;
    address public rewardFoxToken;
    address public fulToken;
    address public lpFoxToken;

    address public foxDistributor;
    address public fulDistributor;
    address public rbsExecutor;

    bool public fulMingingStatus = false;

    mapping(address => bool) public stakingPoolMap;

    address[] public timeLockPoolList;    
    mapping(uint256 => address) public timeLockPoolMap1;
    mapping(address => bool) public timeLockPoolMap2;

    address[] public fulTimeLockPoolList;    
    mapping(uint256 => address) public fulTimeLockPoolMap;

    modifier onlyStakingPool() {
        require(stakingPoolMap[msg.sender], "Not staking pool");
        _;
    }    

    modifier onlyGovernance() {
        require(msg.sender == governance, "unauthorized access");
        _;
    }

    modifier onlyRBSExecutor() {
        require(msg.sender == rbsExecutor, "unauthorized access");
        _;
    }    

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(        
        address initialOwner,

        address _governance,

        address _usdtToken,
        address _foxToken,
        address _stakedFoxToken,
        address _rewardFoxToken,
        address _fulToken,
        address _lpFoxToken

    ) public initializer {        
        __Ownable_init(initialOwner);

        governance = _governance;

        usdtToken = _usdtToken;
        foxToken = _foxToken;
        stakedFoxToken = _stakedFoxToken;
        rewardFoxToken = _rewardFoxToken;
        fulToken = _fulToken;
        lpFoxToken = _lpFoxToken;   
    }

    function setGovernance(address _governance) external onlyOwner {
        governance = _governance;
    }

    function setFoxDistributor(address _foxDistributor) external onlyOwner {
        foxDistributor = _foxDistributor;
    }

    function setFulDistributor(address _fulDistributor) external onlyOwner {
        fulDistributor = _fulDistributor;
    }
    
    function setRBSExecutor(address _rbsExecutor) external onlyOwner {
        rbsExecutor = _rbsExecutor;
    }

    function setStakingPool(address _stakingPool) external onlyOwner {    
        //require(stakingPoolMap[_stakingPool] == false, "Staking pool already set");

        stakingPoolMap[_stakingPool] = true;
    }

    function setTimeLockPool(uint256 _lockDays, address _timeLockPool) external onlyOwner {
        //require(timeLockPoolMap1[_lockDays] == address(0), "TimeLock pool already set");

        timeLockPoolMap1[_lockDays] = _timeLockPool;
        timeLockPoolMap2[_timeLockPool] = true;
        timeLockPoolList.push(_timeLockPool);
    }

    function setFulTimeLockPool(uint256 _lockDays, address _fulTimeLockPool) external onlyOwner {
        //require(fulTimeLockPoolMap[_lockDays] == address(0), "FulTimeLock pool already set");

        fulTimeLockPoolMap[_lockDays] = _fulTimeLockPool;
        fulTimeLockPoolList.push(_fulTimeLockPool);
    }

    function rebase() external onlyGovernance {

        uint256 foxBalance = IERC20(foxToken).balanceOf(foxDistributor);
        uint256 rewardFoxBalance = IERC20(rewardFoxToken).balanceOf(foxDistributor);
        if(rewardFoxBalance > foxBalance) {
            IMintableERC20(foxToken).mint(foxDistributor, rewardFoxBalance - foxBalance);
        }

        for(uint256 i = 0; i < timeLockPoolList.length; i++) {
            address timeLockPool = timeLockPoolList[i];

            foxBalance = IERC20(foxToken).balanceOf(timeLockPool);
            rewardFoxBalance = IERC20(rewardFoxToken).balanceOf(timeLockPool);
            if(rewardFoxBalance > foxBalance) {
                IMintableERC20(foxToken).mint(timeLockPool, rewardFoxBalance - foxBalance);
            }

            IFoxTimeLockPool(timeLockPool).rebase();
        }

        for(uint256 i = 0; i < fulTimeLockPoolList.length; i++) {
            address fulTimeLockPool = fulTimeLockPoolList[i];

            IFulTimeLockPool(fulTimeLockPool).rebase();
        }
    }

    function startFulMinging() external onlyGovernance {
        fulMingingStatus = true;
    }


    function stake(uint256 _amount, uint256 _stakeDays, bool isReward) external onlyStakingPool{
        IERC20(foxToken).safeTransferFrom(msg.sender, address(this), _amount);
        IMintableERC20(stakedFoxToken).mint(msg.sender, _amount);
        if(isReward && _stakeDays >= 180){
            IMintableERC20(rewardFoxToken).mint(foxDistributor, _amount * REWARD_RATIO / BASE_100);
        }
    }

    function lpBonds(uint256 _lpFoxAmount,uint256 _stakeAmount, uint256 _stakeDays, address inviterAddress,uint256 inviterRewardAmount) external onlyStakingPool{
        IERC20(lpFoxToken).safeTransferFrom(msg.sender, DEAD, _lpFoxAmount);
        IMintableERC20(foxToken).mint(address(this), _stakeAmount + inviterRewardAmount);
        IMintableERC20(stakedFoxToken).mint(msg.sender, _stakeAmount);
        if(_stakeDays >= 180){
            IMintableERC20(rewardFoxToken).mint(foxDistributor, _stakeAmount * REWARD_RATIO / BASE_100);
        }
        if(inviterRewardAmount > 0){
            IERC20(foxToken).safeTransfer(inviterAddress, inviterRewardAmount);
        }
    }

    function burnBonds(uint256 _burnAmount,uint256 _stakeAmount, uint256 _stakeDays, address inviterAddress,uint256 inviterRewardAmount) external onlyStakingPool{
        IERC20(foxToken).safeTransferFrom(msg.sender, DEAD, _burnAmount);
        IMintableERC20(foxToken).mint(address(this), _stakeAmount + inviterRewardAmount);
        IMintableERC20(stakedFoxToken).mint(msg.sender, _stakeAmount);
        if(_stakeDays >= 180){
            IMintableERC20(rewardFoxToken).mint(foxDistributor, _stakeAmount * REWARD_RATIO / BASE_100);
        }
        if(inviterRewardAmount > 0){
            IMintableERC20(rewardFoxToken).mint(DEAD, inviterRewardAmount);
            IERC20(foxToken).safeTransfer(inviterAddress, inviterRewardAmount);
        }
    }

    function redeem(uint256 _amount) external onlyStakingPool{
        IERC20(stakedFoxToken).safeTransferFrom(msg.sender, DEAD, _amount);
        IERC20(foxToken).safeTransfer(msg.sender, _amount);
    }

    function timeLock(uint256 _timeLockId, address _user, uint256 _lockDays, uint256 _amount) external{
        require(stakingPoolMap[msg.sender] || msg.sender == foxDistributor, "unauthorized access");

        address timeLockPool = timeLockPoolMap1[_lockDays];
        require(timeLockPool != address(0), "TimeLock pool not found");

        IMintableERC20(rewardFoxToken).mint(timeLockPool, _amount);
        IFoxTimeLockPool(timeLockPool).timeLock(_timeLockId, _user, _amount);
    }    

    function timeLockFul(uint256 _timeLockId, address _user, uint256 _lockDays, uint256 _amount) external{
        require(msg.sender == fulDistributor, "unauthorized access");

        address fulTimeLockPool = fulTimeLockPoolMap[_lockDays];
        require(fulTimeLockPool != address(0), "FulTimeLock pool not found");

        IERC20(fulToken).safeTransfer(fulTimeLockPool, _amount);
        IFulTimeLockPool(fulTimeLockPool).timeLock(_timeLockId, _user, _amount);
    }

    function lendFox(uint256 _foxAmount) external onlyRBSExecutor{
        IMintableERC20(foxToken).mint(msg.sender, _foxAmount);
    }

    function retrieveUsdt(uint256 _usdtAmount) external onlyRBSExecutor{
        IERC20(usdtToken).safeTransfer(msg.sender, _usdtAmount);
    }
}
