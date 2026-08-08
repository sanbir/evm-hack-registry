// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*  ArkProject NFT Bridge — The bridging process will revert if the
    collection is matched on the destination chain and not matched on the
    source chain  (pwnforce / Codehawks, finding #38504)  HIGH
    SYNTHETIC, cheatcode-free reduction for the EVM Playground.

    Root cause: CollectionManager.sol's `_verifyRequestAddresses()` compares
    the incoming request's L1/L2 collection addresses against L1Bridge's OWN
    stored mappings (_l2ToL1Addresses / _l1ToL2Addresses). Those mappings are
    only ever populated on the chain a collection is WITHDRAWN TO, never on
    the chain it was bridged FROM. So when a collection's L1<->L2 pairing was
    recorded on L2 (from an earlier L1->L2 bridge) but L1's own mapping was
    never written, withdrawing the SAME collection L2->L1 always fails:
    L1Bridge has zero stored mapping for that collection, so the request's
    L1 address never matches `l1Mapping` (which is 0), and
    `_verifyRequestAddresses` unconditionally reverts with
    `InvalidCollectionL1Address()`. Every NFT of that collection already
    bridged out via L2 becomes permanently un-withdrawable on L1 — there is
    no code path in the vulnerable version that can ever populate the
    missing mapping (the fix ADDS one).

    This is an L1-only reduction: the bug's mechanism and its revert are
    entirely on the Solidity (L1Bridge) side, so no Cairo/Starknet component
    is needed to demonstrate the harm — the request's L1/L2 addresses are the
    exact data the L1 bridge receives from a relayed L2 message. */

/// @dev Minimal ERC721 used as the bridged NFT collection.
contract MockERC721 {
    mapping(uint256 => address) public ownerOf;

    function mint(address to, uint256 tokenId) external {
        ownerOf[tokenId] = to;
    }

    function transferFrom(address from, address to, uint256 tokenId) external {
        require(ownerOf[tokenId] == from, "not owner");
        ownerOf[tokenId] = to;
    }
}

/// @dev Faithful reduction of ArkProject's CollectionManager.sol +
///      L1Bridge.sol withdrawal path.
contract L1BridgeLike {
    error InvalidCollectionL1Address();
    error InvalidCollectionL2Address();
    error ErrorVerifyingAddressMapping();

    // L1Bridge's OWN address-pairing storage — populated only on the chain a
    // collection is withdrawn TO. Neither mapping is ever written by the
    // function below (it is `view`), matching the real contract.
    mapping(uint256 => address) internal _l2ToL1Addresses;
    mapping(address => uint256) internal _l1ToL2Addresses;

    MockERC721 public collection;

    constructor(MockERC721 collection_) {
        collection = collection_;
    }

    /// @dev Verbatim reduction of CollectionManager.sol#L111-L149
    ///      `_verifyRequestAddresses()`. `collectionL2Req` is a plain
    ///      `uint256` here in place of Cairo's `snaddress` felt wrapper.
    function _verifyRequestAddresses(
        address collectionL1Req,
        uint256 collectionL2Req
    ) internal view returns (address) {
        address l1Req = collectionL1Req;
        uint256 l2Req = collectionL2Req;
        address l1Mapping = _l2ToL1Addresses[collectionL2Req];
        uint256 l2Mapping = _l1ToL2Addresses[l1Req];

        // L2 address is present in the request and L1 address is not.
        if (l2Req > 0 && l1Req == address(0)) {
            if (l1Mapping == address(0)) {
                // It's the first token of the collection to be bridged.
                return address(0);
            } else {
                // It's not the first token of the collection to be bridged,
                // and the collection tokens were only bridged L2->L1.
                return l1Mapping;
            }
        }

        // L2 address is present, and L1 address too.
        if (l2Req > 0 && l1Req > address(0)) {
            if (l1Mapping != l1Req) {
                // @> VULN: l1Mapping is 0 whenever this collection's L1<->L2
                //    pairing was only ever recorded on L2 (from an earlier
                //    L1->L2 bridge) — L1Bridge's own storage was never
                //    written. This branch has NO path to populate the
                //    mapping; it can only compare and revert.
                //    FIX (upstream): if l1Mapping == 0 && l2Mapping == 0,
                //    WRITE the mapping here instead of reverting.
                revert InvalidCollectionL1Address();
            } else if (l2Mapping != l2Req) {
                revert InvalidCollectionL2Address();
            } else {
                // All addresses match, we don't need to deploy anything.
                return l1Mapping;
            }
        }

        revert ErrorVerifyingAddressMapping();
    }

    /// @dev Reduction of L1Bridge.withdrawTokens(). Releases an
    ///      already-escrowed NFT back to the recipient once address
    ///      verification succeeds.
    function withdrawTokens(
        address collectionL1Req,
        uint256 collectionL2Req,
        uint256 tokenId,
        address to
    ) external returns (address) {
        address verified = _verifyRequestAddresses(collectionL1Req, collectionL2Req);
        collection.transferFrom(address(this), to, tokenId);
        return verified;
    }
}

contract Exploit {
    MockERC721 public collection; // CREATE nonce 1
    L1BridgeLike public bridge; // CREATE nonce 2
    address public user; // CREATE nonce 3

    uint256 public constant TOKEN_ID = 9;
    uint256 public constant COLLECTION_L2_ID = 0xC0FFEE; // the L2-side collection id from the relayed message

    constructor() {
        collection = new MockERC721(); // nonce 1
        bridge = new L1BridgeLike(collection); // nonce 2
        user = address(new UserAccount()); // nonce 3

        // The NFT is already escrowed in the bridge — representing a token
        // that was locked here during an earlier L1->L2 deposit of this
        // same collection, and is now (per the withdrawal message) coming
        // back L2->L1.
        collection.mint(address(bridge), TOKEN_ID);
    }

    function run() external {
        // Confirm the precondition: the NFT is already escrowed in the
        // bridge from an earlier L1->L2 deposit (set up in the constructor).
        address preOwner = collection.ownerOf(TOKEN_ID);
        require(preOwner == address(bridge), "setup: NFT should start escrowed in the bridge");

        // The relayed L2->L1 withdrawal message carries the collection's
        // REAL L1 address (nonzero) and the L2-deployed collection id
        // (nonzero) — exactly the "L2 address present, L1 address too"
        // branch. L1Bridge's own address mappings were never populated
        // (this collection's pairing was only ever recorded on L2), so
        // l1Mapping is 0 and will never equal the real L1 address.
        bool withdrawSucceeded = _tryWithdraw();

        address nftOwner = collection.ownerOf(TOKEN_ID);

        require(!withdrawSucceeded, "harm not demonstrated: withdraw should revert");
        require(nftOwner == address(bridge), "harm not demonstrated: NFT should remain stuck in the bridge");
    }

    function _tryWithdraw() internal returns (bool ok) {
        try bridge.withdrawTokens(address(collection), COLLECTION_L2_ID, TOKEN_ID, user) returns (address) {
            ok = true;
        } catch {
            ok = false;
        }
    }
}

/// @dev Stand-in for the withdrawing user (a plain address holder).
contract UserAccount {}
