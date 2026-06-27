pragma solidity 0.8.4;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import "./interfaces/IAavePool.sol";

contract AaveBoost is Ownable {
    using SafeERC20 for IERC20;

    IAavePool public pool;
    IERC20 public aave;

    uint128 public REWARD;

    constructor(
        IAavePool aavePool_,
        IERC20 aave_,
        uint128 reward_
    ) {
        require(address(aavePool_) != address(0), "AAVE_POOL");
        require(address(aave_) != address(0), "AAVE_TOKEN");
        pool = aavePool_;
        aave = aave_;
        REWARD = reward_;
        // infinite approval
        aave.safeIncreaseAllowance(
            address(pool),
            0xffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff
        );
    }

    function setPool(IAavePool pool_, uint128 newReward_) external onlyOwner {
        pool = pool_;
        REWARD = newReward_;
        aave.safeIncreaseAllowance(
            address(pool),
            0xffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff
        );
    }

    function proxyDeposit(
        IERC20 asset,
        address recipient,
        uint128 amount
    ) external {
        if (aave.balanceOf(address(this)) >= REWARD) {
            aave.safeTransferFrom(msg.sender, address(this), amount);
            pool.deposit(asset, recipient, amount + REWARD, false);
        } else {
            // fallback to a normal deposit
            pool.deposit(asset, recipient, amount, false);
        }
    }
}
