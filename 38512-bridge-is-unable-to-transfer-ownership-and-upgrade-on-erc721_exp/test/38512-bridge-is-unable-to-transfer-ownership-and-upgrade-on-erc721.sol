// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*  ArkProject Starklane (L1 Bridge) — cannot move ERC721Bridgeable ownership
    (CodeHawks / said017, AuditVault 38512).
    SYNTHETIC, cheatcode-free reduction for the EVM Playground.
    Root cause: L2 Bridge has collection_transfer_ownership and collection_upgrade.
    L1 Starklane is the ERC721Bridgeable owner (initialize records msg.sender)
    but exposes no forwarder. The admin call hits UUPSOwnableProxied.fallback
    and reverts, so a compromised bridge stays the minter. */

error NotSupportedError();
error NotPayableError();

abstract contract Ownable {
    address private _owner;

    error OwnableUnauthorizedAccount(address account);

    function owner() public view returns (address) {
        return _owner;
    }

    function _transferOwnership(address newOwner) internal {
        _owner = newOwner;
    }

    function transferOwnership(address newOwner) external onlyOwner {
        _transferOwnership(newOwner);
    }

    modifier onlyOwner() {
        if (msg.sender != _owner) revert OwnableUnauthorizedAccount(msg.sender);
        _;
    }
}

/// Reduced ERC721Bridgeable. mintFromBridge is the audited onlyOwner mint.
contract ERC721Bridgeable is Ownable {
    string private _name;
    string private _symbol;
    bool private _initialized;
    mapping(uint256 => address) public ownerOf;
    mapping(address => uint256) public balanceOf;

    function initialize(bytes calldata data) public {
        require(!_initialized, "Already init");
        _initialized = true;
        (string memory n, string memory s) = abi.decode(data, (string, string));
        _name = n;
        _symbol = s;
        _transferOwnership(msg.sender);
    }

    function name() public view returns (string memory) {
        return _name;
    }

    function symbol() public view returns (string memory) {
        return _symbol;
    }

    function mintFromBridge(address to, uint256 id) public onlyOwner {
        _mint(to, id);
    }

    function upgradeToAndCall(address, bytes memory) external onlyOwner {}

    function _mint(address to, uint256 id) internal {
        require(to != address(0) && ownerOf[id] == address(0), "mint");
        ownerOf[id] = to;
        balanceOf[to] += 1;
    }
}

/// L1 bridge. Owns the collection. No collectionTransferOwnership / collectionUpgrade.
contract Starklane is Ownable {
    ERC721Bridgeable public collection;

    constructor(address admin) {
        _transferOwnership(admin);
        collection = new ERC721Bridgeable();
        collection.initialize(abi.encode("Ark", "ARK"));
    }

    /// Existing withdraw path, reduced: the bridge, as collection owner, mints.
    function mintToSelf(uint256 id) external onlyOwner {
        collection.mintFromBridge(address(this), id);
    }

    // FIX: function collectionTransferOwnership(address collection, address newOwner) external onlyOwner {
    //          ERC721Bridgeable(collection).transferOwnership(newOwner);
    //      }

    fallback() external payable {
        // @> VULN: collectionTransferOwnership and collectionUpgrade are not implemented, so the call reverts.
        revert NotSupportedError();
    }

    receive() external payable {
        revert NotPayableError();
    }
}

contract Exploit {
    uint256 public constant N = 5;
    address public constant REPLACEMENT = address(0xB0B);

    Starklane public bridge;
    ERC721Bridgeable public collection;
    bool public transferReverted;
    address public ownerAfter;
    uint256 public mintedToOldOwner;

    constructor() {
        bridge = new Starklane(address(this));
        collection = bridge.collection();
    }

    function run() external {
        require(collection.owner() == address(bridge), "bridge is collection owner");
        (bool transferred,) = address(bridge).call(
            abi.encodeWithSignature(
                "collectionTransferOwnership(address,address)", address(collection), REPLACEMENT
            )
        );
        transferReverted = !transferred;
        require(transferReverted, "ownership transfer must revert");
        ownerAfter = collection.owner();
        require(ownerAfter == address(bridge), "compromised owner was replaced");
        for (uint256 id = 0; id < N; id++) {
            bridge.mintToSelf(id);
        }
        mintedToOldOwner = collection.balanceOf(address(bridge));
        require(mintedToOldOwner == N, "mint of N did not stay with the old owner");
        require(collection.ownerOf(0) == address(bridge), "id 0");
        require(collection.ownerOf(N - 1) == address(bridge), "last id");
        require(collection.balanceOf(REPLACEMENT) == 0, "replacement received a mint");
    }
}
