// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {Exploit, HeroERC721A} from "./55405-c-02-malicious-users-can-mint-the-double-guaranteed-mints-pe.sol";

/// @dev Auditor fix: write the free-mint flag into the full aux word so bits 24-63 survive.
contract HeroFixed {
    address public immutable holder;
    uint64 public immutable rings;
    uint64 public immutable cap;
    mapping(address => uint256) public balanceOf;
    mapping(address => uint64) private _aux;
    uint256 public paidMinted;

    error NotEligible();
    error AlreadyMinted();
    error CapReached();

    constructor(address _holder, uint64 _rings) {
        holder = _holder;
        rings = _rings;
        cap = _rings * 2;
    }

    function ogMint(address to, bool freeMint, uint64 paidMintQty, uint64 numOfRings) external {
        if (to != holder || numOfRings != rings) revert NotEligible();
        if (freeMint) {
            _ogMint(to, numOfRings);
        } else {
            uint64 already = _aux[to] >> 24;
            uint64 next = already + paidMintQty;
            if (next > numOfRings * 2) revert CapReached();
            uint64 low = _aux[to] & uint64((uint256(1) << 24) - 1);
            _aux[to] = low | (next << 24);
            balanceOf[to] += paidMintQty;
            paidMinted += paidMintQty;
        }
    }

    function _ogMint(address to, uint64 numOfRings) internal {
        uint64 _auxWord = _aux[to];
        uint64 aux = (_auxWord >> 3) & 0x0fffff;
        if (aux == numOfRings) revert AlreadyMinted();
        _aux[to] = uint64(_auxWord | (numOfRings << 3));
        balanceOf[to] += numOfRings;
    }
}

contract Finding55405Test is Test {
    function test_exploit_mints_twice_the_cap() public {
        Exploit e = new Exploit();
        e.run();
        assertEq(e.hero().cap(), 10, "cap");
        assertEq(e.afterFirst(), 10, "first batch is the cap");
        assertEq(uint256(e.auxAfterFree()) >> 24, 0, "paid bits wiped");
        assertEq(e.paid(), 20, "2x cap");
        assertEq(e.minted(), 25, "10+5+10");
        assertEq(e.hero().balanceOf(address(e)), 25, "balance");
    }

    function test_control_stops_at_the_cap() public {
        HeroFixed fixedHero = new HeroFixed(address(this), 5);
        fixedHero.ogMint(address(this), false, 10, 5);
        fixedHero.ogMint(address(this), true, 0, 5);
        vm.expectRevert(HeroFixed.CapReached.selector);
        fixedHero.ogMint(address(this), false, 10, 5);
        assertEq(fixedHero.paidMinted(), 10, "paid stops at the cap");
        assertEq(fixedHero.balanceOf(address(this)), 15, "10 paid + 5 free");
    }
}
