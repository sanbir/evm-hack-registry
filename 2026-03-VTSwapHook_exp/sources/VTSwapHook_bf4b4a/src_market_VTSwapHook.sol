// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.26;

import {console} from "forge-std/console.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {SignedMath} from "@openzeppelin/contracts/utils/math/SignedMath.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "v4-core/src/types/Currency.sol";
import {BalanceDelta, BalanceDeltaLibrary} from "v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "v4-core/src/types/BeforeSwapDelta.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {BaseCustomCurve} from "uniswap-hooks/src/base/BaseCustomCurve.sol";

import {IProtocol} from "src/interfaces/IProtocol.sol";
import {IProtocolSettings} from "src/interfaces/IProtocolSettings.sol";
import {IVTSwapHook} from "src/interfaces/IVTSwapHook.sol";
import {ILntVaultAethir} from "src/interfaces/aethir/ILntVaultAethir.sol";
import {IVestingToken} from "src/interfaces/IVestingToken.sol";
import {IVTSwapHookHelper} from "src/interfaces/IVTSwapHookHelper.sol";

import {ZooERC20} from "src/erc20/ZooERC20.sol";
import {ProtocolOwner} from "src/ProtocolOwner.sol";
import {TokenHelper} from "src/libraries/TokenHelper.sol";

contract VTSwapHook is IVTSwapHook, ProtocolOwner, BaseCustomCurve, ZooERC20, TokenHelper {
    using Math for uint256;
    using SignedMath for int256;
    using SafeCast for uint256;
    using SafeCast for int256;
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;
    using BalanceDeltaLibrary for BalanceDelta;

    address public immutable vault;
    address public immutable VT;
    address public immutable T;

    ///  Whether currency0 is VT token
    bool public isToken0VT;

    uint256 public reserve0;
    uint256 public reserve1;

    /// Minimum liquidity to lock permanently
    uint256 public constant MINIMUM_LIQUIDITY = 1000;

    constructor(
        address _protocol, address _vault, address _poolManager,
        string memory _lpTokenName, string memory _lpTokenSymbol
    )  ProtocolOwner(_protocol) BaseCustomCurve(IPoolManager(_poolManager)) ZooERC20(_lpTokenName, _lpTokenSymbol, _decimals(ILntVaultAethir(_vault).T())) {
        vault = _vault;
        VT = ILntVaultAethir(vault).VT();
        T = ILntVaultAethir(vault).T();
        
        // Determine if VT is currency0 based on address comparison
        isToken0VT = VT < T;
    }

    /* ========== HOOK FUNCTIONS ========== */

    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: true,
            afterInitialize: true,
            beforeAddLiquidity: true,
            beforeRemoveLiquidity: true,
            afterAddLiquidity: false,
            afterRemoveLiquidity: false,
            beforeSwap: true,
            afterSwap: false,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: true,
            afterSwapReturnDelta: false,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    function _afterInitialize(
        address, PoolKey calldata key, uint160, int24
    ) internal view override returns (bytes4) {
        address currency0 = Currency.unwrap(key.currency0);
        address currency1 = Currency.unwrap(key.currency1);
        
        require(
            (currency0 == VT && currency1 == T) || (currency0 == T && currency1 == VT),
            "Invalid pool currencies"
        );
        require(isToken0VT == (currency0 == VT), "Currency0 must be VT");
        
        require(address(key.hooks) == address(this), "Hook mismatch");
        
        return this.afterInitialize.selector;
    }

    /* ========== LIQUIDITIES ========== */

    // Override the _getAmountIn function from BaseCustomCurve/BaseCustomAccounting for add liquidity
    function _getAmountIn(
        AddLiquidityParams memory params
    ) internal view override returns (uint256 amount0, uint256 amount1, uint256 shares) {
        address vtSwapHookHelper = IProtocol(protocol).vtSwapHookHelper();
        (amount0, amount1, shares) = IVTSwapHookHelper(vtSwapHookHelper).doGetAmountIn(
            IVTSwapHook(this), params.amount0Desired, params.amount1Desired, params.amount0Min, params.amount1Min
        );
        
        if (totalSupply() == 0) {
            require(shares > MINIMUM_LIQUIDITY, "Insufficient liquidity minted");
        }
        
        return (amount0, amount1, shares);
    }

    // Override the _getAmountOut function from BaseCustomCurve/BaseCustomAccounting for remove liquidity
    function _getAmountOut(
        RemoveLiquidityParams memory params
    ) internal view override returns (uint256 amount0, uint256 amount1, uint256 shares) {
        shares = params.liquidity;
        require(shares > 0, "No liquidity to remove");
        
        uint256 _totalSupply = totalSupply();
        require(_totalSupply > 0, "No liquidity in the pool");

        amount0 = shares.mulDiv(reserve0, _totalSupply);
        amount1 = shares.mulDiv(reserve1, _totalSupply);
        
        require(amount0 >= params.amount0Min && amount1 >= params.amount1Min, "Insufficient amounts");
    }

    // Override the _mint function from BaseCustomCurve/BaseCustomAccounting to mint LP tokens
    function _mint(AddLiquidityParams memory, BalanceDelta callerDelta, BalanceDelta, uint256 shares) internal override {
        // Handle MINIMUM_LIQUIDITY for first liquidity provision
        if (totalSupply() == 0) {
            require(shares > MINIMUM_LIQUIDITY, "Insufficient liquidity minted");
            shares = shares - MINIMUM_LIQUIDITY;
            ZooERC20._mint(address(this), MINIMUM_LIQUIDITY);
        }

        // Mint LP tokens to the recipient (use msg.sender as recipient)
        ZooERC20._mint(_msgSender(), shares);
        
        // Update reserves based on the actual amounts added
        int128 amount0Delta = callerDelta.amount0();
        int128 amount1Delta = callerDelta.amount1();

        // delta amounts are negative when tokens are added to the pool
        require(amount0Delta < 0 && amount1Delta < 0, "Invalid deltas for minting");
        reserve0 = reserve0 + uint256(int256(-amount0Delta));
        reserve1 = reserve1 + uint256(int256(-amount1Delta));

        emit LiquidityAdded(_msgSender(), uint256(int256(-amount0Delta)), uint256(int256(-amount1Delta)), shares);
    }

    // Override the _burn function from BaseCustomCurve/BaseCustomAccounting to burn LP tokens
    function _burn(RemoveLiquidityParams memory, BalanceDelta callerDelta, BalanceDelta, uint256 shares) internal override {
        require(shares > 0, "Cannot burn 0 shares");

        // Burn LP tokens from the sender
        ZooERC20._burn(_msgSender(), shares);
        
        // Update reserves based on the actual amounts removed
        int128 amount0Delta = callerDelta.amount0();
        int128 amount1Delta = callerDelta.amount1();

        // delta amounts are positive when tokens are removed from the pool
        require(amount0Delta > 0 && amount1Delta > 0, "Invalid deltas for burning");
        reserve0 = reserve0 - uint256(int256(amount0Delta));
        reserve1 = reserve1 - uint256(int256(amount1Delta));
        
        emit LiquidityRemoved(_msgSender(), uint256(int256(amount0Delta)), uint256(int256(amount1Delta)), shares);
    }

    /* ========== SWAP ========== */

    function _getUnspecifiedAmount(
        IPoolManager.SwapParams calldata params
    ) internal override returns (uint256 unspecifiedAmount) {
        uint256 specifiedAmount;
        address vtSwapHookHelper = IProtocol(protocol).vtSwapHookHelper();
        (specifiedAmount, unspecifiedAmount) = IVTSwapHookHelper(vtSwapHookHelper).doGetUnspecifiedAmount(
            IVTSwapHook(this), params.zeroForOne, params.amountSpecified
        );

        // Update reserves after swap
        // Since we're charging a fee, we use the full specified amount for incoming token
        // but use the amount calculated based on the reduced (after-fee) input amount for outgoing token
        bool isTToVT = (params.zeroForOne == !isToken0VT); // True if T -> VT, False if VT -> T
        if (isTToVT) {
            // T -> VT swap (user sends T, receives VT)
            if (isToken0VT) {
                reserve0 -= unspecifiedAmount; // VT decreases (sent to user)
                reserve1 += specifiedAmount;   // T increases (received from user, including fee)
            } else {
                reserve0 += specifiedAmount;   // T increases (received from user, including fee)
                reserve1 -= unspecifiedAmount; // VT decreases (sent to user)
            }
        } else {
            // VT -> T swap (user sends VT, receives T)
            if (isToken0VT) {
                reserve0 += specifiedAmount;   // VT increases (received from user, including fee)
                reserve1 -= unspecifiedAmount; // T decreases (sent to user)
            } else {
                reserve0 -= unspecifiedAmount; // T decreases (sent to user)
                reserve1 += specifiedAmount;   // VT increases (received from user, including fee)
            }
        }

        return unspecifiedAmount;
    }

    /* ========== QUOTER & QUERIES ========== */

    /**
     * @notice Get amount of VT that would be received for a given amount of T
     * @param amountT The amount of T to swap (input amount)
     * @return amountVT The amount of VT that would be received (output amount)
     */
    function getAmountOutTforVT(uint256 amountT) external view returns (uint256 amountVT) {
        address vtSwapHookHelper = IProtocol(protocol).vtSwapHookHelper();
        return IVTSwapHookHelper(vtSwapHookHelper).doGetAmountOutTforVT(IVTSwapHook(this), amountT);
    }
    
    /**
     * @notice Get amount of T that would be received for a given amount of VT
     * @param amountVT The amount of VT to swap (input amount)
     * @return amountT The amount of T that would be received (output amount)
     */
    function getAmountOutVTforT(uint256 amountVT) external view returns (uint256 amountT) {
        address vtSwapHookHelper = IProtocol(protocol).vtSwapHookHelper();
        return IVTSwapHookHelper(vtSwapHookHelper).doGetAmountOutVTforT(IVTSwapHook(this), amountVT);
    }


    /* ========== HELPERS ========== */

    function getParamValue(bytes32 param) public view returns (uint256) {
        address settings = IProtocol(protocol).settings();
        return IProtocolSettings(settings).vaultParamValue(vault, param);
    }

    /// @notice Get the current reserves of VT and T tokens
    /// @return reserveVT The current reserve of VT tokens
    /// @return reserveT The current reserve of T tokens
    function getVTAndTReserves() external view returns (uint256 reserveVT, uint256 reserveT) {
        if (isToken0VT) {
            reserveVT = reserve0;
            reserveT = reserve1;
        } else {
            reserveVT = reserve1;
            reserveT = reserve0;
        }
    }
}