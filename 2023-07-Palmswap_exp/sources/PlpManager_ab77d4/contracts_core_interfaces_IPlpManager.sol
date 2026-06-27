// SPDX-License-Identifier: MIT

pragma solidity 0.8.19;

import "./IVault.sol";

interface IPlpManager {
    function plp() external view returns (address);

    function usdp() external view returns (address);

    function vault() external view returns (IVault);

    function collateralToken() external view returns (address);

    function cooldownDuration() external returns (uint256);

    function getAumInUsdp(bool maximise) external view returns (uint256);

    function estimatePlpOut(uint256 _amount) external view returns (uint256);

    function estimateTokenIn(uint256 _plpAmount)
        external
        view
        returns (uint256);

    function lastAddedAt(address _account) external returns (uint256);

    function addLiquidity(
        uint256 _amount,
        uint256 _minUsdp,
        uint256 _minPlp
    ) external returns (uint256);

    function addLiquidityForAccount(
        address _fundingAccount,
        address _account,
        uint256 _amount,
        uint256 _minUsdp,
        uint256 _minPlp
    ) external returns (uint256);

    function removeLiquidity(
        uint256 _plpAmount,
        uint256 _minOut,
        address _receiver
    ) external returns (uint256);

    function removeLiquidityForAccount(
        address _account,
        uint256 _plpAmount,
        uint256 _minOut,
        address _receiver
    ) external returns (uint256);

    function setShortsTrackerAveragePriceWeight(
        uint256 _shortsTrackerAveragePriceWeight
    ) external;

    function setCooldownDuration(uint256 _cooldownDuration) external;
}
