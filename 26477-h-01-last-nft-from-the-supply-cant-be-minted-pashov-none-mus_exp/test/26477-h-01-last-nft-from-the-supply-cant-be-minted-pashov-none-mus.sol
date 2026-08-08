// SPDX-License-Identifier: MIT
pragma solidity ^0.8.21;

/*//////////////////////////////////////////////////////////////////////////
    MuseumOfMahomes — [H-01] Last NFT from the supply can't be minted
    Finding 26477 (Pashov Audit Group, 2023-09) — HIGH

    Root cause: MuseumOfMahomes.mint / mintPhysical guard the supply with
        if (nextId + amount >= MAX_SUPPLY) revert ExceedsMaxSupply();
    The `>=` is an off-by-one: when nextId == MAX_SUPPLY - 1 and amount == 1,
    the sum equals MAX_SUPPLY exactly, so the guard reverts even though that
    mint would bring the collection to exactly MAX_SUPPLY tokens (tokenIds
    0..MAX_SUPPLY-1). The final tokenId (MAX_SUPPLY - 1) can therefore NEVER
    be minted — permanent value loss to the protocol.

    This is a self-contained reduction. mint() is copied VERBATIM from the
    audited (pre-fix) MuseumOfMahomes, with the blamed `>=` line preserved.
    The solady ERC721 base and unrelated metadata/delegation/royalty code are
    replaced with a minimal faithful `_mint` (balance/owner/totalSupply). Only
    MAX_SUPPLY is scaled down (3090 -> 5) so the in-browser recorder does not
    have to replay ~3090 SSTORE mint iterations; the off-by-one boundary the
    bug lives on is independent of the constant's magnitude.
//////////////////////////////////////////////////////////////////////////*/

/// @notice Reduced MuseumOfMahomes. mint()'s body is copied verbatim from the
///         audited source; the blamed supply guard uses the vulnerable `>=`.
contract MuseumOfMahomes {
    // Scaled down from 3090 for in-browser recording; last tokenId is
    // MAX_SUPPLY - 1 because minting starts at 0.
    uint256 internal constant MAX_SUPPLY = 5; // audited value: 3090
    uint256 internal constant BOXSET_SIZE = 6;
    uint256 public totalSupply = 0;
    uint256 public nextId = 0;
    uint256 public price = type(uint256).max; // Prevents minting until real price is set

    address public owner;
    mapping(address => bool) public treasury;

    // minimal ERC721 state (faithful subset of solady ERC721)
    mapping(uint256 => address) public ownerOf;
    mapping(address => uint256) public balanceOf;

    event MintBoxSet(uint256 indexed startTokenId, uint256 endTokenId);

    error ExceedsMaxSupply();
    error MintZero();
    error Unauthorized();
    error WrongEthAmount();
    error WrongBoxSetMultiple();

    constructor() {
        owner = msg.sender;
    }

    modifier onlyOwner() {
        if (msg.sender != owner) revert Unauthorized();
        _;
    }

    function setPrice(uint256 newPrice) external onlyOwner {
        price = newPrice;
    }

    /// @dev treasury addresses may mint without paying (a real protocol feature);
    ///      used here to exercise mint() without ETH plumbing.
    function setTreasury(address who, bool ok) external onlyOwner {
        treasury[who] = ok;
    }

    function _mint(address to, uint256 tokenId) internal {
        ownerOf[tokenId] = to;
        balanceOf[to] += 1;
    }

    /// @notice mint() copied VERBATIM from the audited MuseumOfMahomes; the
    ///         supply guard uses the vulnerable `>=`.
    function mint(address to, uint256 amount, bool mintBoxSet) external payable {
        if (msg.value != amount * price && !treasury[msg.sender]) revert WrongEthAmount();
        if (amount == 0) revert MintZero();
        if (nextId + amount >= MAX_SUPPLY) revert ExceedsMaxSupply(); // @> VULN: `>=` blocks the final NFT (nextId+amount == MAX_SUPPLY should be allowed)
        if (mintBoxSet) {
            if (amount % BOXSET_SIZE != 0) revert WrongBoxSetMultiple();
            emit MintBoxSet(nextId, nextId + amount - 1);
        }
        unchecked {
            uint256 length = nextId + amount;
            for (uint256 tokenId = nextId; tokenId < length; ++tokenId) {
                _mint(to, tokenId);
            }
            nextId += amount;
            totalSupply += amount;
        }
    }
}

/// @notice Deploys the museum, mints everything except the last NFT, then shows
///         the final NFT of the supply can NEVER be minted (one-tx, no cheats).
contract Exploit {
    MuseumOfMahomes public museum;
    address public constant BUYER = address(0xB0B);

    uint256 public constant MAX_SUPPLY = 5;

    bool public lastNftUnmintable; // true once the final mint reverts

    address public attacker;

    constructor() {
        attacker = msg.sender;
        museum = new MuseumOfMahomes();
        // Owner enables minting and lets this harness mint via the treasury path.
        museum.setPrice(1); // any non-zero real price
        museum.setTreasury(address(this), true);
    }

    function run() external {
        // Mint every NFT except the last one: MAX_SUPPLY - 1 tokens (ids 0..MAX_SUPPLY-2).
        uint256 allButOne = MAX_SUPPLY - 1;
        museum.mint(BUYER, allButOne, false);

        // Sanity: the collection is one short of full, and the final slot is free.
        require(museum.totalSupply() == allButOne, "did not mint all-but-one");
        require(museum.nextId() == allButOne, "nextId mismatch");

        // Try to mint the final NFT (tokenId MAX_SUPPLY-1). nextId + amount ==
        // MAX_SUPPLY exactly, so the `>=` guard reverts — it can NEVER be minted.
        try museum.mint(BUYER, 1, false) {
            lastNftUnmintable = false;
        } catch {
            lastNftUnmintable = true;
        }

        // HARM: the last NFT of MAX_SUPPLY is permanently un-mintable. The
        // collection is forever capped one below its intended supply — direct
        // value loss to the protocol (an NFT that can never be sold/minted).
        require(lastNftUnmintable, "last NFT was mintable - bug absent");
        require(museum.totalSupply() == MAX_SUPPLY - 1, "supply not stuck below MAX_SUPPLY");
        require(museum.ownerOf(MAX_SUPPLY - 1) == address(0), "final tokenId should be unminted");
    }
}
