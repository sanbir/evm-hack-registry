// SPDX-License-Identifier: MIT
pragma solidity ^0.8.9;

interface IPlatypusTreasure {
    function isSolvent(
        address _user,
        address _token,
        bool _open
    ) external view returns (bool solvent, uint256 debtAmount);
}
