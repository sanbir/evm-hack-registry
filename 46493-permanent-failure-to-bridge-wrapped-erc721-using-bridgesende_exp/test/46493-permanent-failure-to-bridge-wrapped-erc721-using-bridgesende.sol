// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*//////////////////////////////////////////////////////////////////////////
    Sweep n Flip Bridge — Permanent failure to bridge wrapped ERC721
    (Cantina, Nov 2024; finding #46493)

    SYNTHETIC, cheatcode-free reduction for the EVM Playground.

    Root cause: Bridge.sendERC721UsingNative / _getPayloadMessage fetches NFT
    metadata (tokenURI / name / symbol) from the ORIGIN collection address even
    when the user is bridging a WRAPPED WERC721. On the destination chain the
    origin ERC721 has no code, so the call reverts and the wrap can never be
    redeemed — the original NFT stays permanently locked in the source bridge.

    Bug line preserved with @> VULN. Harm: original NFT locked forever because
    the reverse-bridge of the wrap always reverts.
//////////////////////////////////////////////////////////////////////////*/

interface IERC721Metadata {
    function name() external view returns (string memory);
    function symbol() external view returns (string memory);
    function tokenURI(uint256 tokenId) external view returns (string memory);
    function ownerOf(uint256 tokenId) external view returns (address);
    function transferFrom(address from, address to, uint256 tokenId) external;
}

/// @dev Minimal ERC721 collection (origin asset).
contract MockERC721 is IERC721Metadata {
    string public name = "TestNFT";
    string public symbol = "TNFT";
    mapping(uint256 => address) public ownerOf;
    mapping(uint256 => string) internal _uri;
    mapping(address => mapping(address => bool)) public isApprovedForAll;

    function mint(address to, uint256 id, string memory uri_) external {
        ownerOf[id] = to;
        _uri[id] = uri_;
    }

    function tokenURI(uint256 id) external view returns (string memory) {
        require(ownerOf[id] != address(0) || bytes(_uri[id]).length > 0, "NO_TOKEN");
        return _uri[id];
    }

    function setApprovalForAll(address op, bool ok) external {
        isApprovedForAll[msg.sender][op] = ok;
    }

    function transferFrom(address from, address to, uint256 id) external {
        require(ownerOf[id] == from, "NOT_OWNER");
        require(from == msg.sender || isApprovedForAll[from][msg.sender], "NOT_AUTH");
        ownerOf[id] = to;
    }
}

/// @dev Minimal WERC721 wrap of an origin collection on a remote chain.
contract WERC721 is IERC721Metadata {
    address public immutable originAddress;
    uint256 public immutable originChainId;
    string public name;
    string public symbol;
    mapping(uint256 => address) public ownerOf;
    mapping(uint256 => string) internal _uri;
    mapping(address => mapping(address => bool)) public isApprovedForAll;

    constructor(address origin_, uint256 originChainId_, string memory name_, string memory symbol_) {
        originAddress = origin_;
        originChainId = originChainId_;
        name = name_;
        symbol = symbol_;
    }

    function mint(address to, uint256 id, string memory uri_) external {
        ownerOf[id] = to;
        _uri[id] = uri_;
    }

    function tokenURI(uint256 id) external view returns (string memory) {
        return _uri[id];
    }

    function setApprovalForAll(address op, bool ok) external {
        isApprovedForAll[msg.sender][op] = ok;
    }

    function transferFrom(address from, address to, uint256 id) external {
        require(ownerOf[id] == from, "NOT_OWNER");
        require(from == msg.sender || isApprovedForAll[from][msg.sender], "NOT_AUTH");
        ownerOf[id] = to;
    }
}

/// @notice Reduced Bridge — getPayload / send path for ERC721.
///         Faithful bug: metadata is read from the origin address when the
///         user supplies a wrapped collection.
contract Bridge {
    struct WrapperInfo {
        address originAddress;
        address wrappedAddress;
        uint256 originEvmChainId;
    }

    // origin on this chain → locked NFT custody
    mapping(address => mapping(uint256 => address)) public lockedOwner; // collection => id => original owner
    // wrappedAddress => info (on "destination" side)
    mapping(address => WrapperInfo) public wrapperOf;
    // originAddress => wrap (when registered on dest)
    mapping(address => address) public wrapOfOrigin;

    address public lastFailedToken; // diagnostic: address that tokenURI was called on
    bool public lastSendSucceeded;

    function registerWrapper(address wrapped) external {
        WERC721 w = WERC721(wrapped);
        wrapperOf[wrapped] =
            WrapperInfo({originAddress: w.originAddress(), wrappedAddress: wrapped, originEvmChainId: w.originChainId()});
        wrapOfOrigin[w.originAddress()] = wrapped;
    }

    /// @dev Lock origin NFT on source chain (simulates successful outbound bridge).
    function lockOrigin(address collection, uint256 tokenId, address user) external {
        IERC721Metadata(collection).transferFrom(user, address(this), tokenId);
        lockedOwner[collection][tokenId] = user;
    }

    /// @notice Bridge ERC721 (origin OR wrap). Builds a cross-chain payload and
    ///         takes custody of the NFT. Reverts when metadata lookup hits a
    ///         codeless origin address on the wrap-return path.
    function sendERC721UsingNative(uint256 /* destEvmChainId */, address ERC721Address_, uint256[] memory tokenIds_)
        external
        payable
    {
        lastSendSucceeded = false;
        _getPayload(ERC721Address_, tokenIds_);

        // Only reached if payload build succeeded — take custody.
        for (uint256 i = 0; i < tokenIds_.length; i++) {
            IERC721Metadata(ERC721Address_).transferFrom(msg.sender, address(this), tokenIds_[i]);
        }
        lastSendSucceeded = true;
    }

    /// @dev Reduced _getPayload / _getPayloadMessage with the blamed bug.
    function _getPayload(address ERC721Address_, uint256[] memory tokenIds_) internal {
        WrapperInfo memory w = wrapperOf[ERC721Address_];

        // Intended: if wrapping, currChain = wrapped, origin = origin.
        // BUG (pre-fix): metadata always fetched via a path that resolves to the
        // ORIGIN address when the input is a wrap — origin has no code on this chain.
        address originERC721Address =
            w.originAddress == address(0) ? ERC721Address_ : w.originAddress;

        // FIX (finding): use currChainAddress_ (= wrap when wrap) for IERC721Metadata:
        //   address curr = w.originAddress == address(0) ? ERC721Address_ : w.wrappedAddress;
        //   IERC721Metadata metadata = IERC721Metadata(curr);
        lastFailedToken = originERC721Address;
        IERC721Metadata metadata = IERC721Metadata(originERC721Address); // @> VULN: metadata from ORIGIN even when bridging a wrap

        // These calls succeed for origin-on-source, REVERT for wrap-on-dest:
        metadata.name();
        metadata.symbol();
        for (uint256 i = 0; i < tokenIds_.length; i++) {
            metadata.tokenURI(tokenIds_[i]);
        }
    }

    function isLocked(address collection, uint256 tokenId) external view returns (bool) {
        return lockedOwner[collection][tokenId] != address(0);
    }
}

/// @dev Demonstrates: origin locked on "source"; wrap on "dest" can never be
///      reverse-bridged because payload build calls tokenURI on a codeless origin.
contract Exploit {
    MockERC721 public originNft;
    WERC721 public wrappedNft;
    Bridge public bridge;
    address public user;

    // Codeless stand-in for the origin collection address as seen from the dest chain.
    // In the finding, origin lives only on the ETH fork; on POLY the address has no code.
    address public constant ORIGIN_ON_DEST = address(0xe0dBab467aaea6B2e33EbaD8fdAe07235242D566);

    constructor() {
        user = address(0xBEEF);
        bridge = new Bridge();
        originNft = new MockERC721();
        // Wrap claims origin is ORIGIN_ON_DEST (codeless here), not address(originNft).
        wrappedNft = new WERC721(ORIGIN_ON_DEST, 1, "TestNFT", "TNFT");
        bridge.registerWrapper(address(wrappedNft));

        // User owns origin NFT #1 on source; bridge locks it (successful outbound).
        originNft.mint(user, 1, "ipfs://origin/1");
        // Transfer via prank-less path: mint to bridge custody simulating lock.
        // Re-mint path: transferFrom needs approval — mint directly then lock via user sim.
        originNft.mint(address(this), 2, "ipfs://origin/2");
        originNft.setApprovalForAll(address(bridge), true);
        bridge.lockOrigin(address(originNft), 2, address(this));

        // User holds the wrap on dest.
        wrappedNft.mint(address(this), 2, "ipfs://wrap/2");
        wrappedNft.setApprovalForAll(address(bridge), true);
    }

    function run() external {
        // Precondition: original NFT #2 is locked in the bridge (source custody).
        require(bridge.isLocked(address(originNft), 2), "origin must be locked");
        require(wrappedNft.ownerOf(2) == address(this), "attacker/user holds wrap");

        // Attempt reverse-bridge of the WRAPPED NFT — must permanently fail.
        uint256[] memory ids = new uint256[](1);
        ids[0] = 2;
        bool reverted = false;
        try bridge.sendERC721UsingNative{value: 0}(1, address(wrappedNft), ids) {
            reverted = false;
        } catch {
            reverted = true;
        }
        require(reverted, "wrap bridge should revert");
        require(!bridge.lastSendSucceeded(), "send must not succeed");

        // HARM: wrap still with user (can't burn/redeem), origin still locked forever.
        // (lastFailedToken cannot be observed after a full revert — state rolls back.)
        require(wrappedNft.ownerOf(2) == address(this), "wrap not transferable through bridge");
        require(bridge.isLocked(address(originNft), 2), "origin permanently locked");
        // Confirm the wrap's origin pointer is the codeless address used by the bug path.
        require(wrappedNft.originAddress() == ORIGIN_ON_DEST, "wrap origin pointer");
        require(ORIGIN_ON_DEST.code.length == 0, "origin must be codeless on dest");
        (address regOrigin,,) = bridge.wrapperOf(address(wrappedNft));
        require(regOrigin == ORIGIN_ON_DEST, "bridge maps wrap to codeless origin");
    }
}
