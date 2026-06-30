// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.26;

interface IProtocolOwner {

    function protocol() external view returns (address);

    function owner() external view returns(address);
  
}