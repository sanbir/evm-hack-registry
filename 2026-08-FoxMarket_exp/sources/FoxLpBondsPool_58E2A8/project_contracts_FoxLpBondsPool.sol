// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import './FoxPoolBase.sol';

interface ISwapRouter {
    function getAmountsOut(uint amountIn, address[] memory path) external view returns (uint[] memory amounts);

    function swapExactTokensForTokens(
        uint amountIn,
        uint amountOutMin,
        address[] calldata path,
        address to,
        uint deadline
    ) external returns (uint[] memory amounts);

    function addLiquidity(
        address tokenA,
        address tokenB,
        uint amountADesired,
        uint amountBDesired,
        uint amountAMin,
        uint amountBMin,
        address to,
        uint deadline
    ) external returns (uint amountA, uint amountB, uint liquidity);
}

contract FoxLpBondsPool is FoxPoolBase, Initializable, OwnableUpgradeable {
    using SafeERC20 for IERC20;   

    uint256 public constant MIN_AMOUNT = 100 * 1e18;
    uint256 public constant INVITER_REWARD_RATIO = 300;
    uint256 public constant INVITER_REWARD_MIN_AMOUNT = 1000 * 1e18;

    address public discountRatioLogAddress;

    address public lpFoxToken;
    
    uint256 public discountRateFrom;
    uint256 public discountRateTo;

    address [] public usdtToFoxPath;
    address [] public foxToUsdtPath;

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(
        address initialOwner,

        uint256 _stakeDays, 
        address _treasury,

        address _logAddress,
        address _referralAddress,
        address _rewardRatioLogAddress,
        address _discountRatioLogAddress,

        address _usdtToken,
        address _foxToken,
        address _stakedFoxToken,        
        address _swapRouter,
        address _lpFoxToken,
        
        uint256 _rewardRateFrom,
        uint256 _rewardRateTo,
        uint256 _discountRateFrom,
        uint256 _discountRateTo,

        address _governance

        ) public initializer {
        __Ownable_init(initialOwner);

        initFoxPoolCommon(_stakeDays, _treasury, _logAddress, _referralAddress, _rewardRatioLogAddress, _usdtToken, _foxToken, _stakedFoxToken, _swapRouter, _rewardRateFrom, _rewardRateTo, _governance);

        discountRatioLogAddress = _discountRatioLogAddress;

        lpFoxToken = _lpFoxToken;
        
        discountRateFrom = _discountRateFrom;
        discountRateTo = _discountRateTo;

        IERC20(stakedFoxToken).approve(treasury, type(uint256).max);
        IERC20(lpFoxToken).approve(treasury, type(uint256).max);

        usdtToFoxPath.push(usdtToken);
        usdtToFoxPath.push(foxToken);
        foxToUsdtPath.push(foxToken);
        foxToUsdtPath.push(usdtToken);

        IERC20(usdtToken).approve(swapRouter, type(uint256).max);
        IERC20(foxToken).approve(swapRouter, type(uint256).max);
    }

    function setGovernance(address _governance) external onlyOwner {
        governance = _governance;
    }

    function getDiscountRate(uint256 _timestamp) public view returns (uint256){
        if(discountRateTo == 0){
            return 0;
        }
        uint256 ratio = IRewardRatioLog(discountRatioLogAddress).getRatio(_timestamp);
        return discountRateFrom + (discountRateTo - discountRateFrom) * ratio / BASE_100;
    }

    function getAlignedDiscountRate(uint256 _timestamp) public view returns (uint256){
        if(discountRateTo == 0){
            return 0;
        }
        uint256 ratio = IRewardRatioLog(discountRatioLogAddress).getAlignedRatio(_timestamp);
        return discountRateFrom + (discountRateTo - discountRateFrom) * ratio / BASE_100;
    }

    function getSwapPrice(uint256 _timestamp) public view returns (uint256, uint256){
        if(_timestamp == 0){
            _timestamp = block.timestamp / TIME_BASE * TIME_BASE;
        }
        uint256[] memory amountsOut = ISwapRouter(swapRouter).getAmountsOut(1e18, foxToUsdtPath);
        uint256 swapPrice = amountsOut[1];
        if(discountRateTo > 0){
            swapPrice = swapPrice * (BASE_100 - getDiscountRate(_timestamp)) / BASE_100;
        }
        return (swapPrice, amountsOut[1]);
    }

    function stake(uint256 _usdtAmount, uint256 _swapPrice) external {
        require(_usdtAmount >= MIN_AMOUNT, "usdtAmount invalid");
        address inviterAddress = IReferral(referralAddress).referralMap(msg.sender);
        require(inviterAddress != address(0), "no referral");

        IERC20(usdtToken).safeTransferFrom(msg.sender, address(this), _usdtAmount);
        _usdtAmount = IERC20(usdtToken).balanceOf(address(this)); // if there's another usdt transfered to this contract, we need to get the actual amount

        uint256 startTime = block.timestamp / TIME_BASE * TIME_BASE;

        (uint256 swapPrice, ) = getSwapPrice(startTime);
        if(swapPrice > _swapPrice){
            require((swapPrice - _swapPrice) * BASE_100 / _swapPrice <= 100, "swapPrice invalid");
        }

        uint256 stakeAmount = _usdtAmount * 1e18 / swapPrice;                

        ISwapRouter(swapRouter).swapExactTokensForTokens(_usdtAmount / 2, 0, usdtToFoxPath, address(this), block.timestamp);
        
        uint256 usdtBalance = IERC20(usdtToken).balanceOf(address(this));
        uint256 foxBalance = IERC20(foxToken).balanceOf(address(this));        
        (, , uint256 liquidity) = ISwapRouter(swapRouter).addLiquidity(usdtToken, foxToken, usdtBalance, foxBalance, 0, 0, address(this), block.timestamp);

        usdtBalance = IERC20(usdtToken).balanceOf(address(this));
        if(usdtBalance > 0){
            IERC20(usdtToken).safeTransfer(msg.sender, usdtBalance);
        }

        uint256 inviterRewardAmount = 0;
        if(stakeDays >= 180 && _usdtAmount >= INVITER_REWARD_MIN_AMOUNT){
            inviterRewardAmount = stakeAmount * INVITER_REWARD_RATIO / BASE_100;
        }

        ITreasury(treasury).lpBonds(liquidity, stakeAmount, stakeDays, inviterAddress, inviterRewardAmount);

        uint256 stakeId = ILog(logAddress).getBlockIdListCount();
        ILog(logAddress).addBlockId();
        
        uint256 endTime = startTime + stakeDays * 1 days;
        if(stakeDays == 0){
            endTime = startTime + TIME_BASE;
        }

        stakeInfoMap[stakeId] = StakeInfo({
            stakeId: stakeId,
            user: msg.sender,
            stakeStartTime: startTime,
            rewardStartTime: startTime,
            stakeEndTime: endTime,
            amount: stakeAmount,
            amountRedeemed: 0,
            amountRewardPending: 0,
            amountRewardClaimed: 0,
            fulMingingStartTime: 0,
            fulMingingEndTime: 0
        });

        emit UserStake(
            stakeId, 
            msg.sender, 
            startTime, 
            startTime, 
            endTime, 
            stakeAmount,      
            _usdtAmount - usdtBalance,
            swapPrice,
            inviterRewardAmount,
            block.timestamp);
    }
}
