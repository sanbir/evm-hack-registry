// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "./interfaces/ILiquidityDistributionManager.sol";
import "./base/AbstractRewards.sol";
import "./interfaces/IEscrow.sol";

contract PythiaTokenStaking is Ownable, ReentrancyGuard, ERC20, AbstractRewards {
    using SafeERC20 for IERC20;

    IERC20 public depositToken;
    IERC20 public rewardToken;
    ILiquidityDistributionManager public distributor;
    address feeReceiver;
    uint256 public withdrawFee;
    uint256 constant base = 100;

    IEscrow public escrowPool;
    uint256 public escrowPortion; // how much is escrowed 1e18 == 100%

    struct Epoch {
        uint256 length; // in seconds
        uint256 end; // timestamp
        uint256 distributed; // amount
    }
    Epoch public epoch;

    event Deposited(uint256 amount, address depositor);
    event Withdrawn(address depositor, uint256 amount);
    event RewardsClaimed(address _user, uint256 _escrowedAmount, uint256 _nonEscrowedAmount);

    constructor(
        string memory poolName,
        string memory poolSymbol,
        address _distributor,
        uint256 _epochLength, 
        address _escrowPool, 
        uint256 _escrowPortion
    )
        ERC20(poolName, poolSymbol)
        AbstractRewards(balanceOf, totalSupply)
        Ownable(msg.sender)
    {
        distributor = ILiquidityDistributionManager(_distributor);
        epoch = Epoch({
            length: _epochLength,
            end: block.timestamp,
            distributed: 0
        });
        escrowPool = IEscrow(_escrowPool);
        escrowPortion = _escrowPortion;
    }

    function updateEcrowPool(address _escrow) external onlyOwner {
        require(_escrow != address(0), "zero add");
        escrowPool = IEscrow(_escrow);
    }

    function mint(address account, uint256 amount) internal {
        super._update(address(0), account, amount);
        adjustPoints(account, -int256(amount));
    }

    function burn(address account, uint256 amount) internal {
        super._update(account, address(0), amount);
        adjustPoints(account, int256(amount));
    }

    function stake(uint256 amount) external nonReentrant {
        require(amount > 0, "Amount must be greater than 0");

        depositToken.safeTransferFrom(_msgSender(), address(this), amount);

        // mints staked share
        mint(_msgSender(), amount);
        emit Deposited(amount, _msgSender());
    }

    function unstake() external nonReentrant {
        require(
            balanceOf(msg.sender) > 0,
            "Deposit does not exist"
        );
        uint256 amount = balanceOf(msg.sender);

        // Burn staked share
        burn(_msgSender(), amount);

        // withdraw fee
        uint256 fee = (amount * withdrawFee) / base;
        if(fee > 0) {
            depositToken.transfer(feeReceiver, fee);
        }
        uint256 userShare = amount - fee;
        // Return tokens
        depositToken.safeTransfer(_msgSender(), userShare);
        emit Withdrawn(_msgSender(), amount);
    }

    function setFeeReceiver(address _add) external onlyOwner() {
        require(_add != address(0), "zero address");
        feeReceiver = _add;
    }

    function setWithdrawFee(uint256 _fee) external onlyOwner {
        require(_fee <= 10, "max 10% is allowed");
        withdrawFee = _fee;
    }

    function distributeRewards() public nonReentrant {
        if (epoch.end <= block.timestamp) {
            uint256 timePassed = epoch.length + (block.timestamp - epoch.end);
            epoch.end = block.timestamp + epoch.length;

            uint256 amount = distributor.distributor(timePassed);
            if(amount > 0) {
                _distributeRewards(amount);
                epoch.distributed += amount;
            }
        }
    }

    function claimRewards() external {
        distributeRewards();
        uint256 rewardAmount = setupClaim(_msgSender());
        uint256 escrowedRewardAmount = rewardAmount * escrowPortion / 1e18;
        uint256 nonEscrowedRewardAmount = rewardAmount - escrowedRewardAmount;

        if(escrowedRewardAmount != 0 && address(escrowPool) != address(0)) {
            escrowPool.vestingLock(_msgSender(), escrowedRewardAmount);
        }

        // ignore dust
        if(nonEscrowedRewardAmount > 1) {
            rewardToken.safeTransfer(_msgSender(), nonEscrowedRewardAmount);
        }

        emit RewardsClaimed(_msgSender(), escrowedRewardAmount, nonEscrowedRewardAmount);
    }

    function addDepositRewardToken(address depositTokenAddress, address rewardTokenAddress) external onlyOwner {
        require(depositTokenAddress != address(0), "Deposit token must be set");
        require(rewardTokenAddress != address(0), "reward token must be set");

        depositToken = IERC20(depositTokenAddress);
        rewardToken = IERC20(rewardTokenAddress);

        if(rewardTokenAddress != address(0) && address(escrowPool) != address(0)) {
            IERC20(rewardTokenAddress).approve(address(escrowPool), type(uint256).max);
        }
    }

    function setEpochTime(uint256 _duration) external onlyOwner {
        require(_duration > 0, "epoch cannot be zero");

        epoch.length = _duration;
    }

    function changeDistributor(ILiquidityDistributionManager _add) external onlyOwner {
        require(address(_add) != address(0), "zero address");
        distributor = _add;
    }
}
