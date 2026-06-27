// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";

contract Relationship is Ownable {
    using EnumerableSet for EnumerableSet.AddressSet;

    address public constant ROOT = address(1);

    mapping(address => bool) operators;
    mapping(address => address) public referrers;
    mapping(address => EnumerableSet.AddressSet) private _referrals;

    event Binded(address indexed user, address referrer);

    error CallerNotOperator();
    error UserHasBinded();
    error ReferrerNotBind();

    constructor() Ownable(msg.sender) {}

    function hasBinded(address user) public view returns (bool) {
        if (user == ROOT) {
            return true;
        }
        return referrers[user] != address(0);
    }

    function referrals(address user) public view returns (address[] memory) {
        return _referrals[user].values();
    }

    function referralsCount(address user) public view returns (uint256) {
        return _referrals[user].length();
    }

    function referralByIndex(address user, uint256 index) public view returns (address) {
        return _referrals[user].at(index);
    }

    function referralsByRange(address user, uint256 from, uint256 to) public view returns (address[] memory) {
        address[] memory items = new address[](to - from);
        for (uint index = from; index < to; index++) {
            items[index - from] = _referrals[user].at(index);
        }
        return items;
    }

    function setOperator(address opeartor, bool state) public onlyOwner {
        operators[opeartor] = state;
    }

    function bind(address referrer) public {
        _bind(msg.sender, referrer);
    }

    function bind(address user, address referrer) public {
        if (operators[msg.sender] == false) revert CallerNotOperator();
        _bind(user, referrer);
    }

    function _bind(address user, address referrer) private {
        if (hasBinded(user) == true) revert UserHasBinded();
        if (hasBinded(referrer) == false) revert ReferrerNotBind();

        referrers[user] = referrer;
        _referrals[referrer].add(user);

        emit Binded(user, referrer);
    }
}
