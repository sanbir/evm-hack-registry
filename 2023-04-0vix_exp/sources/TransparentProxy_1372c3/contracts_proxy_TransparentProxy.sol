//SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.4;

import "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";

contract TransparentProxy is TransparentUpgradeableProxy {
    constructor(address logic, address admin, bytes memory data) payable TransparentUpgradeableProxy(logic, admin, data) {}
}