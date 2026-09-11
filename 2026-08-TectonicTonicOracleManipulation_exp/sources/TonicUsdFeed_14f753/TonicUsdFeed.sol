// SPDX-License-Identifier: RECONSTRUCTED
pragma solidity ^0.5.16;

/**
 * RECONSTRUCTED stub for Tectonic TONIC/USD feed
 * (0x14f753940720C1Fa4247Cd464C7EA28c806d123F).
 * Docs: price sources = VVS Finance, Crypto.com Exchange.
 */
contract TonicUsdFeed {
    uint8 public decimals = 12;

    // Returns manipulable spot-influenced mark (no on-chain TWAP enforced here).
    function latestAnswer() external view returns (int256) {
        return 2076321; // line ~24 — pumped answer at fork
    }
}
