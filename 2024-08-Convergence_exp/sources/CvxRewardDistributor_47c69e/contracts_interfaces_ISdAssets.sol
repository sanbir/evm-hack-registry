// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import "@openzeppelin/contracts/token/ERC721/extensions/IERC721Enumerable.sol";
import "./ICvgControlTower.sol";
import "./ISdtBuffer.sol";

struct SdGaugeReward {
    address token;
    address distributor;
    uint256 period_finish;
    uint256 rate;
    uint256 last_update;
    uint256 integral;
}

interface IOperator {
    function token() external view returns (IERC20Metadata);

    function deposit(uint256 amount, bool isLock, bool isStake, address receiver) external;
}

interface ISdAsset is IERC20Metadata {
    function sdAssetGauge() external view returns (IERC20);

    function initialize(
        ICvgControlTower _cvgControlTower,
        IERC20 _sdAssetGauge,
        string memory setName,
        string memory setSymbol
    ) external;

    function setSdAssetBuffer(address _sdAssetBuffer) external;

    function mint(address to, uint256 amount) external;

    function operator() external view returns (IOperator);
}

interface ISdAssetGauge is IERC20Metadata {
    function deposit(uint256 value, address addr) external;

    function deposit(uint256 value, address addr, bool claimRewards) external;

    function staking_token() external view returns (IERC20);

    function reward_count() external view returns (uint256);

    function reward_tokens(uint256 i) external view returns (IERC20);

    function claim_rewards(address account) external;

    function set_rewards_receiver(address account) external;

    function claimable_reward(address account, address token) external view returns (uint256);

    function set_reward_distributor(address rewardToken, address distributor) external;

    function deposit_reward_token(address rewardToken, uint256 amount) external;

    function admin() external view returns (address);

    function working_balances(address) external view returns (uint256);

    function working_supply() external view returns (uint256);

    function reward_data(address rewardToken) external view returns (SdGaugeReward memory);
}
