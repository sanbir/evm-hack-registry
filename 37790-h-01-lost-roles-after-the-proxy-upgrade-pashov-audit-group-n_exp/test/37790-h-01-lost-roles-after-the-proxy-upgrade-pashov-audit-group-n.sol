// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*  Gains Network — lost roles after the proxy upgrade (Pashov, H-01)
    SYNTHETIC, cheatcode-free reduction for the EVM Playground.
    Root cause: the upgraded AddressStore inserts gnsStaking and linkErc677
    ahead of accessControl, so hasRole reads slot 4 while the live role
    bits still sit at slot 2. Vulnerable line preserved verbatim below (@> VULN). */

uint8 constant ROLES_MANAGER = 2;

error LostRole();

contract StoreV1 {
    uint64 private _initialized;
    bool private _initializing;
    address public gns;
    mapping(address => mapping(uint8 => bool)) public accessControl;
    address public gnsStaking;

    function grantRole(address account, uint8 role) external {
        accessControl[account][role] = true; // S2
    }

    function hasRole(address account, uint8 role) external view returns (bool) {
        return accessControl[account][role];
    }

    function setGnsStaking(address a) external {
        if (!accessControl[msg.sender][ROLES_MANAGER]) revert LostRole();
        gnsStaking = a;
    }
}

contract StoreV2 {
    uint64 private _initialized;
    bool private _initializing;
    address public gns;
    address public gnsStaking;
    address public linkErc677;
    // AddressStore.accessControl moves from slot 2 to slot 4 once Addresses holds three addresses.
    mapping(address => mapping(uint8 => bool)) public accessControl;

    function hasRole(address account, uint8 role) external view returns (bool) {
        return accessControl[account][role]; // @> VULN: hasRole now hashes slot 4; the granted role is still stored at slot 2
        // FIX: append gnsStaking and linkErc677 after accessControl so the mapping stays at slot 2
    }

    function setGnsStaking(address a) external {
        if (!accessControl[msg.sender][ROLES_MANAGER]) revert LostRole();
        gnsStaking = a;
    }
}

contract StoreFixed {
    uint64 private _initialized;
    bool private _initializing;
    address public gns;
    mapping(address => mapping(uint8 => bool)) public accessControl;
    address public gnsStaking;
    address public linkErc677;

    function hasRole(address account, uint8 role) external view returns (bool) {
        return accessControl[account][role];
    }

    function setGnsStaking(address a) external {
        if (!accessControl[msg.sender][ROLES_MANAGER]) revert LostRole();
        gnsStaking = a;
    }
}

contract DiamondProxy {
    bytes32 internal constant IMPL_SLOT = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;

    function upgradeTo(address impl) external {
        assembly {
            sstore(IMPL_SLOT, impl)
        }
    }

    fallback() external payable {
        assembly {
            let impl := sload(0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc)
            calldatacopy(0, 0, calldatasize())
            let ok := delegatecall(gas(), impl, 0, calldatasize(), 0, 0)
            returndatacopy(0, 0, returndatasize())
            switch ok
            case 0 { revert(0, returndatasize()) }
            default { return(0, returndatasize()) }
        }
    }
}

contract Manager {
    function trySet(address proxy, address next) external returns (bool ok) {
        try StoreV2(proxy).setGnsStaking(next) {
            return true;
        } catch {
            return false;
        }
    }
}

contract Exploit {
    StoreV1 public v1; // nonce 1
    StoreV2 public v2; // nonce 2 — vulnerable layout
    DiamondProxy public proxy; // nonce 3
    Manager public manager; // nonce 4
    bool public roleBefore;
    bool public roleAfter;
    bool public gatedBricked;

    constructor() {
        v1 = new StoreV1();
        v2 = new StoreV2();
        proxy = new DiamondProxy();
        manager = new Manager();
    }

    function run() external {
        proxy.upgradeTo(address(v1)); // S1
        StoreV1(address(proxy)).grantRole(address(manager), ROLES_MANAGER);
        roleBefore = StoreV1(address(proxy)).hasRole(address(manager), ROLES_MANAGER); // S3
        require(roleBefore, "role missing before upgrade");
        require(manager.trySet(address(proxy), address(0x1234)), "pre-upgrade gate failed");
        proxy.upgradeTo(address(v2)); // S4
        roleAfter = StoreV2(address(proxy)).hasRole(address(manager), ROLES_MANAGER);
        require(!roleAfter, "role survived");
        gatedBricked = !manager.trySet(address(proxy), address(0x5678));
        require(gatedBricked, "role gate still open");
        roleBefore = gatedBricked; // S6
    }
}
