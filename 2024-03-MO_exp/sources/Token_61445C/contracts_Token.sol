// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

contract Token is ERC20, Ownable {
    using SafeERC20 for IERC20;

    address public pair;

    mapping(address => bool) public whitelist;

    error Forbidden();

    constructor() ERC20("MO", "MO") Ownable(msg.sender) {
        whitelist[address(0)] = true;
        whitelist[msg.sender] = true;

        _mint(msg.sender, 1000000000 * 10 ** decimals());
    }

    function decimals() public view virtual override returns (uint8) {
        return 4;
    }

    function setPair(address _pair) public onlyOwner {
        pair = _pair;
        whitelist[pair] = true;
    }

    function setWhitelist(address user, bool state) public onlyOwner {
        whitelist[user] = state;
    }

    function _update(address from, address to, uint256 value) internal virtual override {
        if (whitelist[from] == false && to != pair) revert Forbidden();
        _updateReward(from);
        _updateReward(to);
        super._update(from, to, value);
    }

    address public vault;
    address public burn = 0x000000000000000000000000000000000000dEaD;

    address public rewardsToken;
    address public rewardsDistribution;
    uint256 public rewardPerTokenStored;
    mapping(address => uint256) public userRewardPerTokenPaid;
    mapping(address => uint256) public rewards;

    event RewardAdded(uint256 reward);
    event RewardPaid(address indexed user, uint256 reward);

    function setVault(address _vault) public onlyOwner {
        vault = _vault;
    }

    function setBurn(address _burn) public onlyOwner {
        burn = _burn;
    }

    function setRewardsToken(address _rewardsToken) public onlyOwner {
        rewardsToken = _rewardsToken;
    }

    function setRewardsDistribution(address _rewardsDistribution) public onlyOwner {
        rewardsDistribution = _rewardsDistribution;
    }

    function earned(address user) public view returns (uint256) {
        return rewards[user] + (balanceOf(user) * (rewardPerTokenStored - userRewardPerTokenPaid[user])) / 1e18;
    }

    function getReward() public {
        _updateReward(msg.sender);
        uint256 reward = rewards[msg.sender];
        if (reward > 0) {
            rewards[msg.sender] = 0;
            IERC20(rewardsToken).safeTransfer(msg.sender, reward);
            emit RewardPaid(msg.sender, reward);
        }
    }

    function notifyRewardAmount(uint256 reward) public {
        if (msg.sender != rewardsDistribution) revert Forbidden();

        uint256 amount = totalSupply() - balanceOf(vault) - balanceOf(pair) - balanceOf(burn);
        if (amount == 0) {
            return;
        }

        rewardPerTokenStored += (reward * 1e18) / amount;
        emit RewardAdded(reward);
    }

    function claim(address token, address to, uint256 amount) public onlyOwner {
        if (token == address(0)) {
            payable(to).transfer(amount);
        } else {
            IERC20(token).safeTransfer(to, amount);
        }
    }

    function _updateReward(address user) private {
        if (rewardPerTokenStored == 0) {
            return;
        }
        rewards[user] = earned(user);
        userRewardPerTokenPaid[user] = rewardPerTokenStored;
    }
}
