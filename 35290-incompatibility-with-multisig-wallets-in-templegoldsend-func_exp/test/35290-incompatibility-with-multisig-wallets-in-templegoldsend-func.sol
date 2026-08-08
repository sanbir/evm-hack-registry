// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*//////////////////////////////////////////////////////////////////////////
    TempleGold — Incompatibility with multisig wallets in `send()`
    Finding 35290 (n0kto, Codehawks) — HIGH

    Root cause: TempleGold.send() (the LayerZero OFT cross-chain bridge entry
    point) hard-requires `msg.sender == _to` before it will debit and bridge a
    user's tokens:

        if (msg.sender != _to) revert ITempleGold.NonTransferrable(msg.sender, _to);

    This assumes a user's address is identical on the source and destination
    chain. That is FALSE for any multisig / smart-contract wallet (Safe, etc.)
    deployed with a different address (different owner set, different salt,
    different factory nonce) on the destination chain — which is common. Such
    a user can NEVER bridge their TempleGold to their own multisig on another
    chain: every legitimate cross-chain send to their real wallet permanently
    reverts. Plain EOAs (same address on every chain) are unaffected — so the
    bug is invisible in an EOA-only test suite.

    This file is a self-contained, cheatcode-free reduction. The `send()`
    body is copied verbatim (the `@>` line preserved) with the LayerZero
    OFTCore machinery (endpoint quoting/messaging, options encoding) replaced
    by minimal mocks that preserve exactly the behavior the bug needs: a
    debit of the sender's balance gated by the `msg.sender == _to` check. A
    tiny `Multisig` wallet contract stands in for a Safe-style wallet so the
    call is genuinely initiated BY that wallet (msg.sender == the wallet),
    exactly like a real multisig-initiated bridge transaction.
//////////////////////////////////////////////////////////////////////////*/

/// @dev Minimal stand-in for LayerZero-OFT's SendParam (only the fields the
///      vulnerable function actually reads).
struct SendParam {
    uint32 dstEid;
    bytes32 to;
    uint256 amountLD;
    uint256 minAmountLD;
}

/// @dev Minimal stand-in for LayerZero's MessagingFee / MessagingReceipt / OFTReceipt.
struct MessagingFee {
    uint256 nativeFee;
}

struct MessagingReceipt {
    bytes32 guid;
}

struct OFTReceipt {
    uint256 amountSentLD;
    uint256 amountReceivedLD;
}

interface ITempleGold {
    error NonTransferrable(address sender, address to);
}

/// @notice Reduced TempleGold. The cross-chain send() body below is copied
///         verbatim from the audited contract (LayerZero OFTCore `send()`
///         override); `_debit`/`_lzSend`/message building are collapsed to
///         the minimal local bookkeeping the bug needs (this contract never
///         actually needs a live LayerZero endpoint to demonstrate the harm
///         — the harm IS that send() reverts before any bridging happens).
contract TempleGold is ITempleGold {
    mapping(address => uint256) public balanceOf;
    event OFTSent(bytes32 guid, uint32 dstEid, address indexed from, uint256 amountSentLD, uint256 amountReceivedLD);

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    /// @dev Verbatim reduction of TempleGold::send (LayerZero OFTCore.send override).
    function send(SendParam calldata _sendParam, MessagingFee calldata, address)
        external
        payable
        virtual
        returns (MessagingReceipt memory msgReceipt, OFTReceipt memory oftReceipt)
    {
        /// cast bytes32 to address
        address _to = address(uint160(uint256(_sendParam.to)));
        /// @dev user can cross-chain transfer to self
        // @> VULN: hard-requires msg.sender == _to. A multisig wallet's address on the
        // destination chain almost never equals its address on the source chain, so this
        // reverts EVERY legitimate cross-chain send to a user's own multisig, permanently.
        // FIX: drop this check (OFT already restricts spending via balance/allowance) or
        // replace it with a signed-intent / allow-list check that doesn't assume address
        // equality across chains.
        if (msg.sender != _to) revert NonTransferrable(msg.sender, _to);

        // @dev Applies the token transfers regarding this send() operation.
        uint256 amountSentLD = _sendParam.amountLD;
        uint256 amountReceivedLD = _sendParam.amountLD;
        balanceOf[msg.sender] -= amountSentLD;

        msgReceipt = MessagingReceipt(keccak256(abi.encode(msg.sender, _to, amountSentLD, block.number)));
        oftReceipt = OFTReceipt(amountSentLD, amountReceivedLD);

        emit OFTSent(msgReceipt.guid, _sendParam.dstEid, msg.sender, amountSentLD, amountReceivedLD);
    }
}

/// @dev Minimal stand-in for a Safe-style multisig wallet: a smart-contract
///      account that can be deployed at DIFFERENT addresses on different
///      chains (different owner set / salt / factory nonce), unlike an EOA.
///      It forwards the bridge call so msg.sender at TempleGold is genuinely
///      this wallet's own address.
contract Multisig {
    function bridge(TempleGold tg, SendParam memory p, MessagingFee memory fee, address refund)
        external
        returns (bool ok, bytes4 errSelector)
    {
        (bool success, bytes memory ret) =
            address(tg).call(abi.encodeWithSelector(TempleGold.send.selector, p, fee, refund));
        ok = success;
        if (!success && ret.length >= 4) errSelector = bytes4(ret);
    }
}

contract Exploit {
    TempleGold public templeGold; // CREATE nonce 1
    Multisig public multisigMainnet; // CREATE nonce 2 — the user's multisig, deployed here
    Multisig public multisigArb; // CREATE nonce 3 — the SAME user's multisig on Arbitrum: a DIFFERENT address

    bool public selfSendWorked;
    bool public multisigSendReverted;

    constructor() {
        templeGold = new TempleGold();
        multisigMainnet = new Multisig();
        multisigArb = new Multisig();
        templeGold.mint(address(multisigMainnet), 100 ether);
    }

    function run() external {
        // --- Control: the multisig bridges to ITSELF (same address on both
        //     "chains" in this reduction) — the address-equality check trivially
        //     passes, exactly like it would for a plain EOA. ---
        SendParam memory selfParam = SendParam({
            dstEid: 30110,
            to: bytes32(uint256(uint160(address(multisigMainnet)))),
            amountLD: 1 ether,
            minAmountLD: 1 ether
        });
        (bool ok1,) = multisigMainnet.bridge(templeGold, selfParam, MessagingFee(0), address(multisigMainnet));
        selfSendWorked = ok1;

        // --- Harm: the SAME user, now bridging to their OWN multisig wallet
        //     as deployed on the destination chain. Because a Safe-style wallet
        //     is deployed independently per chain, `multisigArb` is a DIFFERENT
        //     address than `multisigMainnet` even though it is controlled by
        //     the exact same owners. This is a completely ordinary, legitimate
        //     bridging operation for this user — yet it permanently reverts,
        //     and there is no workaround: TempleGold can NEVER be bridged to
        //     that user's multisig on the destination chain. ---
        SendParam memory msigParam = SendParam({
            dstEid: 30110,
            to: bytes32(uint256(uint160(address(multisigArb)))),
            amountLD: 1 ether,
            minAmountLD: 1 ether
        });
        (bool ok2, bytes4 errSel) =
            multisigMainnet.bridge(templeGold, msigParam, MessagingFee(0), address(multisigMainnet));
        multisigSendReverted = !ok2;

        require(ok1, "control failed: same-address self-send should have succeeded");
        require(!ok2, "harm not demonstrated: multisig cross-chain send unexpectedly succeeded");
        require(errSel == ITempleGold.NonTransferrable.selector, "harm not demonstrated: wrong revert reason");
        require(
            templeGold.balanceOf(address(multisigMainnet)) == 99 ether,
            "harm not demonstrated: balances inconsistent with a blocked bridge"
        );
    }
}
