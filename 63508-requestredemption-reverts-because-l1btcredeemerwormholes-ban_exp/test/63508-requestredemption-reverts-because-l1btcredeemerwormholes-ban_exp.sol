// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {
    Exploit,
    L1BTCRedeemerWormhole,
    L1BTCRedeemerWormholeFixed,
    MiniToken,
    Bank,
    Bridge,
    TBTCVault,
    WormholeTokenBridge,
    BitcoinTx,
    IBridgeTypes
} from "./63508-requestredemption-reverts-because-l1btcredeemerwormholes-ban.sol";

contract L1BTCRedeemerWormholeBankCreditTest is Test {
    address internal constant SINK = 0x000000000000000000000000000000000000D00d;
    uint256 internal constant SATOSHI_MULTIPLIER = 10**10;
    uint256 internal constant REDEEM_TBTC = 10 ether;

    bytes20 internal constant WALLET_PUBKEY_HASH =
        bytes20(0x1234567890AbcdEF1234567890aBcdef12345678);

    // ── The vulnerable path: redemption reverts, tBTC stranded (DoS harm) ──
    function test_exploit_redemptionRevertsBankBalanceNotCredited() public {
        Exploit e = new Exploit();
        e.run();

        // The real Wormhole redemption reverted because the redeemer's Bank
        // balance was never credited (Bank._transferBalance require).
        assertTrue(e.redemptionReverted(), "redemption must revert (DoS)");
        assertEq(
            e.revertReason(),
            "Transfer amount exceeds balance",
            "revert is the Bank balance-check, i.e. the missing credit"
        );

        // Harm marker: the permanently stranded bridged tBTC recorded to SINK.
        assertEq(e.lockedTbtc(), REDEEM_TBTC, "stranded tBTC magnitude");
        MiniToken marker = MiniToken(e.markerAddr());
        assertEq(
            marker.balanceOf(SINK),
            REDEEM_TBTC,
            "LOCKED-tBTC marker records 10 tBTC stranded at SINK"
        );

        // Real state: after the (reverted) redemption, the redeemer holds no
        // usable balance in the Bank — the redemption path is bricked.
        Bank bank = Bank(e.bankAddr());
        assertEq(
            bank.balanceOf(e.redeemerAddr()),
            0,
            "redeemer never obtained a Bank balance"
        );
    }

    // ── Negative control: isolate the missing credit as the exact cause ──
    // The corrected redeemer credits the Bank balance (via tbtcVault.unmint)
    // before calling the Bridge, so the identical redemption COMPLETES.
    function test_control_fixedCreditsBankBalance_redemptionSucceeds() public {
        MiniToken tbtc = new MiniToken("tBTC", "tBTC");
        Bank bank = new Bank();
        Bridge bridge = new Bridge(bank);
        TBTCVault vault = new TBTCVault(tbtc, bank);
        bytes memory script = hex"76a9141234567890abcdef1234567890abcdef1234567888ac";
        WormholeTokenBridge wh = new WormholeTokenBridge(
            tbtc,
            REDEEM_TBTC,
            script,
            bytes32(uint256(uint160(0xB0B)))
        );
        L1BTCRedeemerWormholeFixed redeemer = new L1BTCRedeemerWormholeFixed(
            address(bridge),
            address(tbtc),
            address(bank),
            address(vault),
            address(wh)
        );

        BitcoinTx.UTXO memory utxo = BitcoinTx.UTXO({
            txHash: bytes32(uint256(0xDEAD)),
            txOutputIndex: 0,
            txOutputValue: uint64(REDEEM_TBTC / SATOSHI_MULTIPLIER)
        });

        uint64 amountInSatoshis = uint64(REDEEM_TBTC / SATOSHI_MULTIPLIER);

        // Same redemption, corrected contract — must NOT revert.
        redeemer.requestRedemption(WALLET_PUBKEY_HASH, utxo, hex"00");

        // The Bridge successfully pulled the redeemer's satoshi Bank balance.
        assertEq(
            bank.balanceOf(address(bridge)),
            amountInSatoshis,
            "Bridge received the redeemer's satoshi balance"
        );
        assertEq(
            bank.balanceOf(address(redeemer)),
            0,
            "redeemer's credited balance fully transferred to the Bridge"
        );

        // A pending redemption was recorded — the redemption path works.
        uint256 key = _redemptionKey(WALLET_PUBKEY_HASH, script);
        IBridgeTypes.RedemptionRequest memory req = bridge.pendingRedemptions(key);
        assertEq(req.redeemer, address(redeemer), "pending redemption recorded");
        assertEq(req.requestedAmount, amountInSatoshis, "pending amount matches");
    }

    function _redemptionKey(bytes20 walletPubKeyHash, bytes memory script)
        internal
        pure
        returns (uint256)
    {
        bytes32 scriptHash = keccak256(script);
        uint256 key;
        /* solhint-disable-next-line no-inline-assembly */
        assembly {
            mstore(0, scriptHash)
            mstore(32, walletPubKeyHash)
            key := keccak256(0, 52)
        }
        return key;
    }
}
