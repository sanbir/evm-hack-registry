// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.18;

interface IProxy {
    function balanceOf(address _gauge) external view returns (uint256);

    function harvest(address _gauge) external;

    function claimManyRewards(address _gauge, address[] memory _token) external;

    function deposit(address _gauge, address _token) external;

    function withdraw(
        address _gauge,
        address _token,
        uint256 _amount
    ) external returns (uint256);

    function approveFactory(address _factory, bool _approved) external;

    function strategies(address) external view returns (address);

    function approveStrategy(address _gauge, address _strategy) external;

    function revokeStrategy(address _gauge) external;

    function approvedFactories(address _factory) external view returns (bool);
}

interface IVoter {
    function strategy() external view returns (address);
}

interface IGauge {
    function lp_token() external view returns (address);

    function balanceOf(address _gauge) external view returns (uint256);

    function deposit(uint256 _amount) external;

    function withdraw(uint256 _amount) external;

    function claim_rewards() external;

    function inflation_rate() external view returns (uint256);

    function working_supply() external view returns (uint256);

    function totalSupply() external view returns (uint256);

    function working_balances(address) external view returns (uint256);

    function deposit_reward_token(address, uint256) external;
}

interface IVault {
    function pricePerShare() external view returns (uint256);

    function totalAssets() external view returns (uint256);

    function controller() external view returns (address);

    function amm() external view returns (address);
}

interface IController {
    // use this to borrow out funds to push to max util
    function create_loan(uint256 collateral, uint256 debt, uint256 n) external;

    function collateral_token() external view returns (address);
}

interface IPool {
    function get_dy(
        uint256 i,
        uint256 j,
        uint256 dx
    ) external view returns (uint256);

    function exchange(
        uint256 i,
        uint256 j,
        uint256 dx,
        uint256 min_dy
    ) external returns (uint256);

    function price_oracle(uint256 i) external view returns (uint256);
}

interface IPeriphery {
    function total_debt() external view returns (uint256);

    function rate() external view returns (uint256);

    function gauge_relative_weight(address) external view returns (uint256);
}
