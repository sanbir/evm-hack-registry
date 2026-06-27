// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import "./LockContract.sol";
import "./MintContract.sol";

contract TunnelContract is LockContract, MintContract, UUPSUpgradeable {
    constructor(uint64 version, address hubAddress, string memory tunnelName, bool isLockMode) Constants(version, hubAddress, tunnelName, isLockMode) {}

    function initConfigs(
        address admin,
        address[] calldata executors,
        uint256 threshold,
        uint256 exeIndex,
        address proposer,
        address vault
    ) external initializer {
        _initAdmin(admin);
        _initExecutors(executors, threshold, exeIndex);
        if (proposer != address(0)) {
            _addProposer(proposer);
        }
        if (vault != address(0)) {
            _initVault(vault);
        }
    }

    function upgradeTunnel(uint64 version) public onlyProxy onlyAdmin {
        address newImplementation = ITunnelHub(HUB_ADDRESS).upgradeTunnel(getTunnelName(), IS_LOCK_MODE, version);
        UUPSUpgradeable.upgradeToAndCall(newImplementation, "");
    }

    function _authorizeUpgrade(address newImplementation) internal pure override {}

    function upgradeToAndCall(address, bytes memory) public payable override {
        revert("Method upgradeToAndCall disabled. Use upgradeTunnel.");
    }

    function addToken(uint8 tokenIndex, address tokenAddr) external onlyAdmin {
        _addToken(tokenIndex, tokenAddr);
    }

    function removeToken(uint8 tokenIndex) external onlyAdmin {
        _removeToken(tokenIndex);
    }
}
