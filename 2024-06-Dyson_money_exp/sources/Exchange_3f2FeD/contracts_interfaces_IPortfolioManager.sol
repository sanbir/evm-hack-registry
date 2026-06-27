// SPDX-License-Identifier: MIT
pragma solidity >=0.8.0 <0.9.0;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

interface IPortfolioManager {


    // --- structs

    struct Order {
        bool stake;
        address strategy;
        uint256 amount;
    }

    struct StrategyWeight {
        address strategy;
        uint256 minWeight;
        uint256 targetWeight;
        uint256 maxWeight;
        uint256 riskFactor;
        bool enabled;
        bool enabledReward;
    }

    function deposit() external;

    /**
     * @dev
     * Withdraw target amount assets from strategies
     * Send amount to Exchanger
     * @return withdrawAmount - how much PortfolioManager unstake from strategies
     * @return isBalanced - executed or not balance function on PortfolioManager
     */

    function withdraw(uint256 _amount) external returns (uint256 withdrawAmount, bool isBalanced);

    function getStrategyWeight(address strategy) external view returns (StrategyWeight memory);

    function getAllStrategyWeights() external view returns (StrategyWeight[] memory);

    function claimAndBalance() external;

    function balance() external;

    function getTotalRiskFactor() external view returns (uint256);
}
