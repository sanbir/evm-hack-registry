// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";

contract ReferralRegistryLisa is Ownable {
    using EnumerableSet for EnumerableSet.AddressSet;

    EnumerableSet.AddressSet private whitelist;

    mapping(address => address) private referrer;

    mapping(address => address[]) private referrals;

    event WhitelistAdded(address indexed account);
    event WhitelistRemoved(address indexed account);
    event Bind(address indexed referrer, address indexed referee);
    event BatchBind(address indexed referrer, address[] referees);

    error NotWhitelisted();
    error AlreadyHasReferrer(address user);
    error AlreadyHasReferrals(address user);
    error SelfRefer();
    error ZeroAddress();
    error DepthTooLarge(uint256 requested, uint256 maxAllowed);

    uint256 public constant MAX_DEPTH = 30;

    modifier onlyWhitelisted() {
        if (!whitelist.contains(msg.sender)) revert NotWhitelisted();
        _;
    }

    constructor() Ownable(msg.sender) {
        whitelist.add(msg.sender);
        emit WhitelistAdded(msg.sender);
    }

    function addWhitelist(address account) external onlyOwner {
        if (account == address(0)) revert ZeroAddress();
        if (whitelist.add(account)) {
            emit WhitelistAdded(account);
        }
    }

    function removeWhitelist(address account) external onlyOwner {
        if (whitelist.remove(account)) {
            emit WhitelistRemoved(account);
        }
    }
    
    function isWhitelisted(address account) external view returns (bool) {
        return whitelist.contains(account);
    }

    function getWhitelistCount() external view returns (uint256) {
        return whitelist.length();
    }

    function getWhitelistAt(uint256 index) external view returns (address) {
        return whitelist.at(index);
    }

    function getAllWhitelist() external view returns (address[] memory result) {
        uint256 len = whitelist.length();
        result = new address[](len);
        for (uint256 i = 0; i < len; i++) {
            result[i] = whitelist.at(i);
        }
    }

    function bind(address ref, address referee) external onlyWhitelisted {
        _bindInternal(ref, referee);

        address[] memory arr = new address[](1);
        arr[0] = referee;

        emit BatchBind(ref, arr);
    }

    function bindBatch(address ref, address[] calldata referees) external onlyWhitelisted {
        if (ref == address(0)) revert ZeroAddress();

        uint256 len = referees.length;

        for (uint256 i = 0; i < len; i++) {
            _bindInternal(ref, referees[i]);
        }

        emit BatchBind(ref, referees);
    }

    function _bindInternal(address ref, address referee) internal {
        if (ref == address(0) || referee == address(0)) revert ZeroAddress();
        if (ref == referee) revert SelfRefer();

        if (referrer[referee] != address(0)) revert AlreadyHasReferrer(referee);

        if (referrals[referee].length > 0) revert AlreadyHasReferrals(referee);

        referrer[referee] = ref;
        referrals[ref].push(referee);

        emit Bind(ref, referee);
    }

    function getReferrer(address user) external view returns (bool, address) {
        address r = referrer[user];
        if (r == address(0)) return (false, address(0));
        return (true, r);
    }

    function getDirectReferrals(address user) external view returns (address[] memory) {
        return referrals[user];
    }

    function getDirectReferralCount(address user) external view returns (uint256) {
        return referrals[user].length;
    }

    function getUpwardReferrers(address user, uint256 depth)
        external
        view
        returns (address[] memory chain)
    {
       if (depth == 0) return new address[](0);
        if (depth > MAX_DEPTH) revert DepthTooLarge(depth, MAX_DEPTH);

        address[] memory tmp = new address[](depth);
        uint256 found = 0;
        address cur = user;

        for (uint256 i = 0; i < depth; i++) {
            address r = referrer[cur];
            if (r == address(0)) break;
            tmp[found] = r;
            found++;
            cur = r;
        }

        chain = new address[](found);
        for (uint256 j = 0; j < found; j++) {
            chain[j] = tmp[j];
        }
    }
}