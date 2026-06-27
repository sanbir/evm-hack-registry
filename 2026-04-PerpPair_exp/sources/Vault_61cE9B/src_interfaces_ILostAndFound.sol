// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.4;

import "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";
import "@openzeppelin/contracts/utils/math/SignedMath.sol";
import "@openzeppelin/contracts/utils/math/SafeCast.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";

interface ILostAndFound {

    function VAULT_ROLE() external view returns (bytes32);
    function depositLostFunds(address user, address stable, uint256 amount) external;
    function retrieveLostFunds(address stable) external;
    function retrieveLostFunds(address stable, uint256 amount) external;
    function userBalances(address, address) external view returns (uint256);
}
