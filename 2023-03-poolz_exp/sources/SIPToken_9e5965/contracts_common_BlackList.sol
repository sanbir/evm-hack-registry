//SPDX-License-Identifier: Unlicense
pragma solidity ^0.8.2;

import "@openzeppelin/contracts/access/Ownable.sol";

contract BlackList is Ownable {
    /////// Getters to allow the same blacklist to be used also by other contracts (including upgraded SIP) ///////
    function getBlackListStatus(address _maker) external view returns (bool) {
        return isBlackListed[_maker];
    }

    function getOwner() external view returns (address) {
        return owner();
    }

    mapping(address => bool) public isBlackListed;

    function addBlackList(address _evilUser) public onlyOwner {
        isBlackListed[_evilUser] = true;
        emit AddedBlackList(_evilUser);
    }

    function removeBlackList(address _clearedUser) public onlyOwner {
        isBlackListed[_clearedUser] = false;
        emit RemovedBlackList(_clearedUser);
    }

    event AddedBlackList(address _user);
    event RemovedBlackList(address _user);
}
