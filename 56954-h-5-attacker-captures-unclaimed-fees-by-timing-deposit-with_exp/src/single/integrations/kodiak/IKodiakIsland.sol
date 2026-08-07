// SPDX-License-Identifier: GPL-3.0
pragma solidity >=0.8.19;

import {IERC20} from "openzeppelin-contracts/token/ERC20/IERC20.sol";

import {IUniswapV3MintCallback} from "./pool/IUniswapV3MintCallback.sol";
import {IUniswapV3SwapCallback} from "./pool/IUniswapV3SwapCallback.sol";
import {IUniswapV3Pool} from "./IUniswapV3Pool.sol";

interface IKodiakIsland is
    IERC20,
    IUniswapV3MintCallback,
    IUniswapV3SwapCallback
{
    event Minted(
        address receiver,
        uint256 mintAmount,
        uint256 amount0In,
        uint256 amount1In,
        uint128 liquidityMinted
    );

    event Burned(
        address receiver,
        uint256 burnAmount,
        uint256 amount0Out,
        uint256 amount1Out,
        uint128 liquidityBurned
    );

    event Rebalance(
        address indexed compounder,
        int24 lowerTick_,
        int24 upperTick_,
        uint128 liquidityBefore,
        uint128 liquidityAfter
    );

    event FeesEarned(uint256 feesEarned0, uint256 feesEarned1);

    // User functions
    function mint(
        uint256 mintAmount,
        address receiver
    )
        external
        returns (uint256 amount0, uint256 amount1, uint128 liquidityMinted);

    event UpdateManagerParams(
        uint16 managerFeeBPS,
        address managerTreasury,
        uint16 compounderSlippageBPS,
        uint32 compounderSlippageInterval
    );
    event PauserSet(address indexed pauser, bool status);
    event RestrictedMintSet(bool status);

    function burn(
        uint256 burnAmount,
        address receiver
    )
        external
        returns (uint256 amount0, uint256 amount1, uint128 liquidityBurned);

    function updateManagerParams(
        int16 newManagerFeeBPS,
        address newManagerTreasury,
        int16 newSlippageBPS,
        int32 newSlippageInterval
    ) external;

    function setRestrictedMint(bool enabled) external;

    function setPauser(address _pauser, bool enabled) external;

    function pause() external;

    function unpause() external;

    function renounceOwnership() external;
    function transferOwnership(address newOwner) external;

    // Additional view functions that might be useful to expose:
    function managerBalance0() external view returns (uint256);

    function managerBalance1() external view returns (uint256);

    function managerTreasury() external view returns (address);

    function getUnderlyingBalancesAtPrice(
        uint160 sqrtRatioX96
    ) external view returns (uint256 amount0Current, uint256 amount1Current);
    function manager() external view returns (address);

    function getMintAmounts(
        uint256 amount0Max,
        uint256 amount1Max
    )
        external
        view
        returns (uint256 amount0, uint256 amount1, uint256 mintAmount);

    function getUnderlyingBalances()
        external
        view
        returns (uint256 amount0, uint256 amount1);

    function getPositionID() external view returns (bytes32 positionID);

    function token0() external view returns (IERC20);

    function token1() external view returns (IERC20);

    function upperTick() external view returns (int24);

    function lowerTick() external view returns (int24);

    function pool() external view returns (IUniswapV3Pool);

    function totalSupply() external view returns (uint256);

    function balanceOf(address account) external view returns (uint256);

    function managerFeeBPS() external view returns (uint16);

    function withdrawManagerBalance() external;

    function executiveRebalance(
        int24 newLowerTick,
        int24 newUpperTick,
        uint160 swapThresholdPrice,
        uint256 swapAmountBPS,
        bool zeroForOne
    ) external;

    function rebalance() external;

    function initialize(
        string memory _name,
        string memory _symbol,
        address _pool,
        uint16 _managerFeeBPS,
        int24 _lowerTick,
        int24 _upperTick,
        address _manager_
    ) external;
    function compounderSlippageInterval() external view returns (uint32);

    function compounderSlippageBPS() external view returns (uint16);

    function restrictedMint() external view returns (bool);
}
