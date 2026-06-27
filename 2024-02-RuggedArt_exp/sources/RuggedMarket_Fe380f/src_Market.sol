// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";

import {UUPSUpgradeable} from "@openzeppelin-upgradeable/contracts/proxy/utils/UUPSUpgradeable.sol";
import {OwnableUpgradeable} from "@openzeppelin-upgradeable/contracts/access/OwnableUpgradeable.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin-upgradeable/contracts/utils/ReentrancyGuardUpgradeable.sol";

import {IUniversalRouter} from "@uniswap/universal-router/contracts/interfaces/IUniversalRouter.sol";

interface IRugged {
    function transferFrom(
        address sender,
        address recipient,
        uint256 amount
    ) external;

    function transfer(
        address recipient,
        uint256 amount
    ) external returns (bool);

    /// @notice Returns the amount of tokens owned by `account`.
    function balanceOf(address account) external view returns (uint256);
}

contract RuggedMarket is
    ReentrancyGuardUpgradeable,
    OwnableUpgradeable,
    UUPSUpgradeable,
    IERC721Receiver
{
    error InvalidAmount();
    error TransferFailed();
    error WrongEthSender();
    error InvalidParameter();

    IRugged public ruggedToken;
    IUniversalRouter public immutable UNIVERSAL_ROUTER;
    uint256 public constant ERC721_TOTAL_SUPPLY = 10_000;

    struct Staker {
        uint256 amountStaked;
        uint256 rewardDebt;
    }

    struct Incentive {
        uint256 rewardTotal;
        uint256 startTime;
        uint256 endTime;
        uint256 rewardDistributed;
    }

    struct UniversalRouterExecute {
        bytes commands;
        bytes[] inputs;
        uint256 deadline;
    }

    mapping(address => Staker) public stakers;
    Incentive[] public incentives;
    uint256 public totalStaked;
    uint256 public accRewardPerShare;
    uint256 public marketFees;
    uint256 public lastUpdateTime;

    event Staked(address indexed user, uint256 amount);
    event Unstaked(address indexed user, uint256 amount);
    event RewardClaimed(address indexed user, uint256 amount);
    event IncentiveAdded(
        uint256 rewardTotal,
        uint256 startTime,
        uint256 endTime
    );

    constructor(address _universalRouter) {
        UNIVERSAL_ROUTER = IUniversalRouter(_universalRouter);

        _disableInitializers();
    }

    function initialize(
        address _ruggedTokenAddress
    ) public payable initializer {
        __Ownable_init(msg.sender);
        __ReentrancyGuard_init();
        __UUPSUpgradeable_init();

        ruggedToken = IRugged(_ruggedTokenAddress);
        lastUpdateTime = block.timestamp;
    }

    /// required by the OZ UUPS module
    function _authorizeUpgrade(address) internal override onlyOwner {}

    function addIncentive(
        uint256 _rewardTotal,
        uint256 _startTime,
        uint256 _endTime
    ) external onlyOwner {
        if (_endTime <= _startTime) {
            revert InvalidParameter();
        }
        incentives.push(
            Incentive({
                rewardTotal: _rewardTotal,
                startTime: _startTime,
                endTime: _endTime,
                rewardDistributed: 0
            })
        );
        ruggedToken.transferFrom(msg.sender, address(this), _rewardTotal);

        emit IncentiveAdded(_rewardTotal, _startTime, _endTime);
    }

    function updatePool() internal {
        if (totalStaked == 0) {
            lastUpdateTime = block.timestamp;
            return;
        }
        uint256 reward = calculateReward();
        if (reward > 0) {
            accRewardPerShare += (reward * 1e12) / totalStaked;
        }
        lastUpdateTime = block.timestamp;
    }

    function calculateReward() internal returns (uint256 totalReward) {
        totalReward = 0;
        for (uint256 i = 0; i < incentives.length; i++) {
            Incentive storage inc = incentives[i];
            if (
                block.timestamp > inc.startTime && lastUpdateTime < inc.endTime
            ) {
                uint256 rewardTime = min(block.timestamp, inc.endTime);
                uint256 reward = ((rewardTime -
                    max(inc.startTime, lastUpdateTime)) * inc.rewardTotal) /
                    (inc.endTime - inc.startTime);
                reward = min(reward, inc.rewardTotal - inc.rewardDistributed);
                inc.rewardDistributed += reward;
                totalReward += reward;
            }
        }
        // update market fees
        totalReward += marketFees;
        marketFees = 0;
        return totalReward;
    }

    function stake(uint256 _amount) external nonReentrant {
        if (_amount <= ERC721_TOTAL_SUPPLY) {
            revert InvalidAmount();
        }

        ruggedToken.transferFrom(msg.sender, address(this), _amount);
        updatePool();
        Staker storage staker = stakers[msg.sender];
        if (staker.amountStaked > 0) {
            uint256 pendingReward = (staker.amountStaked * accRewardPerShare) /
                1e12 -
                staker.rewardDebt;
            if (pendingReward > 0) {
                ruggedToken.transfer(msg.sender, pendingReward);
            }
        }
        staker.amountStaked += _amount;
        staker.rewardDebt = (staker.amountStaked * accRewardPerShare) / 1e12;
        totalStaked += _amount;
        emit Staked(msg.sender, _amount);
    }

    function stakeNFTs(uint256[] memory _tokenIds) external nonReentrant {
        for (uint256 i = 0; i < _tokenIds.length; i++) {
            if (_tokenIds[i] > ERC721_TOTAL_SUPPLY) {
                revert InvalidAmount();
            }
            ruggedToken.transferFrom(msg.sender, address(this), _tokenIds[i]);
        }
        updatePool();
        Staker storage staker = stakers[msg.sender];
        if (staker.amountStaked > 0) {
            uint256 pendingReward = (staker.amountStaked * accRewardPerShare) /
                1e12 -
                staker.rewardDebt;
            if (pendingReward > 0) {
                ruggedToken.transfer(msg.sender, pendingReward);
            }
        }
        uint256 _amount = _tokenIds.length * 1 ether;
        staker.amountStaked += _amount;
        staker.rewardDebt = (staker.amountStaked * accRewardPerShare) / 1e12;
        totalStaked += _amount;
        emit Staked(msg.sender, _amount);
    }

    function unstake(uint256 _amount) external nonReentrant {
        Staker storage staker = stakers[msg.sender];
        if (staker.amountStaked < _amount) {
            revert InvalidAmount();
        }
        updatePool();
        uint256 pendingReward = (staker.amountStaked * accRewardPerShare) /
            1e12 -
            staker.rewardDebt;
        if (pendingReward > 0) {
            ruggedToken.transfer(msg.sender, pendingReward);
        }
        staker.amountStaked -= _amount;
        staker.rewardDebt = (staker.amountStaked * accRewardPerShare) / 1e12;
        ruggedToken.transfer(msg.sender, _amount);
        totalStaked -= _amount;
        emit Unstaked(msg.sender, _amount);
    }

    function claimReward() external nonReentrant returns (uint256) {
        updatePool();
        Staker storage staker = stakers[msg.sender];
        uint256 pendingReward = (staker.amountStaked * accRewardPerShare) /
            1e12 -
            staker.rewardDebt;
        if (pendingReward > 0) {
            ruggedToken.transfer(msg.sender, pendingReward);
            staker.rewardDebt =
                (staker.amountStaked * accRewardPerShare) /
                1e12;
            emit RewardClaimed(msg.sender, pendingReward);
        }
        return pendingReward;
    }

    function max(uint256 a, uint256 b) private pure returns (uint256) {
        return a > b ? a : b;
    }

    function min(uint256 a, uint256 b) private pure returns (uint256) {
        return a < b ? a : b;
    }

    function targetedPurchase(uint256[] memory _tokenIds) public {
        ruggedToken.transferFrom(
            msg.sender,
            address(this),
            _tokenIds.length * 1.1 ether
        );
        _targetedPurchase(_tokenIds);
    }

    function _targetedPurchase(uint256[] memory _tokenIds) private {
        for (uint256 i = 0; i < _tokenIds.length; i++) {
            if (_tokenIds[i] > ERC721_TOTAL_SUPPLY) {
                revert InvalidAmount();
            }
            ruggedToken.transferFrom(address(this), msg.sender, _tokenIds[i]);
        }

        marketFees += _tokenIds.length * 0.1 ether;
    }

    function _executeSwap(UniversalRouterExecute calldata swapParam) private {
        /// buy with eth
        if (msg.value > 0) {
            UNIVERSAL_ROUTER.execute{value: msg.value}(
                swapParam.commands,
                swapParam.inputs,
                swapParam.deadline
            );
        } else {
            revert InvalidParameter();
        }
    }

    function targetedPurchase(
        uint256[] memory _tokenIds,
        UniversalRouterExecute calldata swapParam
    ) public payable {
        uint256 beforeSwapBalance = ruggedToken.balanceOf(address(this));
        _executeSwap(swapParam);
        uint256 afterSwapBalance = ruggedToken.balanceOf(address(this));
        uint256 totalAmount = afterSwapBalance - beforeSwapBalance;
        if (totalAmount < _tokenIds.length * 1.1 ether) {
            revert InvalidAmount();
        }
        _targetedPurchase(_tokenIds);
    }

    receive() external payable {
        if (msg.sender != address(UNIVERSAL_ROUTER)) revert WrongEthSender();
    }

    function onERC721Received(
        address,
        /*operator*/
        address,
        /*from*/
        uint256,
        /*tokenId*/
        bytes calldata /*data*/
    ) external pure override returns (bytes4) {
        return this.onERC721Received.selector;
    }
}
