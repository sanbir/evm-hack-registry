// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

// Adshares Bridge exploit — no exploit contract. The real attack was the
// compromised bridge "minter" EOA (0xF54aF6D4d18C8d61F504E530C127eaa05E011414)
// calling wrapTo() directly on WrappedADS three times with fabricated native
// deposit metadata. There is no attack contract to deploy; the EVM Playground
// config for this hack uses `callScript` (see ../2026-05-AdsharesBridge.mjs)
// to replay the three direct wrapTo() calls from the minter EOA. This file is
// kept only so the build tooling has a placeholder artifact name; it is not
// deployed or executed.

interface IWrappedADS {
    function balanceOf(address account) external view returns (uint256);
    function minterAllowance(address minter) external view returns (uint256);
    function wrapTo(address account, uint256 amount, uint64 from, uint64 txid) external returns (bool);
}
