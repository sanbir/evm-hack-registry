// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import "../interface/IFragmentToken.sol";

struct SafeBox {
    /// Either matching a key OR Constants.SAFEBOX_KEY_NOTATION meaning temporarily
    /// held by a bidder in auction.
    uint64 keyId;
    /// The timestamp that the safe box expires.
    uint32 expiryTs;
    /// The owner of the safebox. It maybe outdated due to expiry
    address owner;
}

struct PrivateOffer {
    /// private offer end time
    uint96 endTime;
    /// which token used to accpet the offer
    address token;
    /// price of the offer
    uint96 price;
    address owner;
    /// who should receive the offer
    address buyer;
    uint64 activityId;
    Fees fees;
}

enum AuctionType {
    Owned,
    Expired,
    Vault
}

struct AuctionInfo {
    /// The end time for the auction.
    uint96 endTime;
    /// Bid token address.
    address bidTokenAddress;
    /// Minimum Bid.
    uint96 minimumBid;
    /// The person who trigger the auction at the beginning.
    address triggerAddress;
    uint96 lastBidAmount;
    address lastBidder;
    /// [Deprecated] Whether the auction is triggered by the NFT owner itself？
    /// Note. Don't remove it directly as we need keep mainnet contract layout
    bool isSelfTriggered;
    uint64 activityId;
    /// [Deprecated] fee config
    /// Note. Don't remove it directly as we need keep mainnet contract layout
    uint32 oldFeeRateBips;
    AuctionType typ;
    Fees fees;
}

struct TicketRecord {
    /// who buy the tickets
    address buyer;
    /// Start index of tickets
    /// [startIdx, endIdx)
    uint48 startIdx;
    /// End index of tickets
    uint48 endIdx;
}

struct RaffleInfo {
    /// raffle end time
    uint48 endTime;
    /// max tickets amount the raffle can sell
    uint48 maxTickets;
    /// which token used to buy the raffle tickets
    address token;
    /// owner of raffle
    address owner;
    /// price per ticket
    uint96 ticketPrice;
    uint64 activityId;
    /// total funds collected by selling tickets
    uint96 collectedFund;
    /// total sold tickets amount
    uint48 ticketSold;
    /// whether the raffle is being settling
    bool isSettling;
    /// tickets sold records
    TicketRecord[] tickets;
    Fees fees;
}

struct CollectionState {
    /// The address of the Floor Token cooresponding to the NFTs.
    IFragmentToken floorToken;
    /// Records the active safe box in each time bucket.
    mapping(uint256 => uint256) countingBuckets;
    /// Stores all of the NFTs that has been fragmented but *without* locked up limit.
    uint256[] freeTokenIds;
    /// Huge map for all the `SafeBox`es in one collection.
    mapping(uint256 => SafeBox) safeBoxes;
    /// Stores all the ongoing auctions: nftId => `AuctionInfo`.
    mapping(uint256 => AuctionInfo) activeAuctions;
    /// Stores all the ongoing raffles: nftId => `RaffleInfo`.
    mapping(uint256 => RaffleInfo) activeRaffles;
    /// Stores all the ongoing private offers: nftId => `PrivateOffer`.
    mapping(uint256 => PrivateOffer) activePrivateOffers;
    /// The last bucket time the `countingBuckets` is updated.
    uint64 lastUpdatedBucket;
    /// Next Key Id. This should start from 1, we treat key id `SafeboxLib.SAFEBOX_KEY_NOTATION` as temporarily
    /// being used for activities(auction/raffle).
    uint64 nextKeyId;
    /// Active Safe Box Count.
    uint64 activeSafeBoxCnt;
    /// The number of infinite lock count.
    uint64 infiniteCnt;
    /// Next Activity Id. This should start from 1
    uint64 nextActivityId;
    uint32 lastVaultAuctionPeriodTs;
}

struct UserFloorAccount {
    /// @notice it should be maximum of the `totalLockingCredit` across all collections
    uint96 minMaintCredit;
    /// @notice used to iterate collection accounts
    /// packed with `minMaintCredit` to reduce storage slot access
    address firstCollection;
    /// @notice user vip level related info
    /// 0 - 239 bits: store SafeBoxKey Count per vip level, per level using 24 bits
    /// 240 - 247 bits: store minMaintVipLevel
    /// 248 - 255 bits: remaining
    uint256 vipInfo;
    /// @notice Locked Credit amount which cannot be withdrawn and will be released as time goes.
    uint256 lockedCredit;
    mapping(address => CollectionAccount) accounts;
    mapping(address => uint256) tokenAmounts;
    /// Each account has safebox quota to use per period
    uint32 lastQuotaPeriodTs;
    uint16 safeboxQuotaUsed;
    /// [Deprecated] Each account has vault redemption waiver per period
    uint32 lastWaiverPeriodTs;
    uint96 creditWaiverUsed;
}

struct SafeBoxKey {
    /// locked credit amount of this safebox
    uint96 lockingCredit;
    /// corresponding key id of the safebox
    uint64 keyId;
    /// which vip level the safebox locked
    uint8 vipLevel;
}

struct CollectionAccount {
    mapping(uint256 => SafeBoxKey) keys;
    /// total locking credit of all `keys` in this collection
    uint96 totalLockingCredit;
    /// track next collection as linked list
    address next;
    /// tracking total locked of the collection
    uint32 keyCnt;
    /// Depositing to vault gets quota, redepmtion consumes quota
    uint32 vaultContQuota;
    /// Used to track and clear vault contribution quota when the quota is inactive for a certain duration
    uint32 lastVaultActiveTs;
}

struct Fees {
    FeeRate royalty;
    FeeRate protocol;
}

struct FeeConfig {
    RoyaltyFeeRate royalty;
    SafeboxFeeRate safeboxFee;
    VaultFeeRate vaultFee;
}

struct RoyaltyFeeRate {
    address receipt;
    uint16 marketlist;
    uint16 vault;
    uint16 raffle;
}

struct VaultFeeRate {
    address receipt;
    uint16 vaultAuction;
    uint16 redemptionBase;
}

struct SafeboxFeeRate {
    address receipt;
    uint16 auctionOwned;
    uint16 auctionExpired;
    uint16 raffle;
    uint16 marketlist;
}

struct FeeRate {
    address receipt;
    uint16 rateBips;
}

/// Internal Structure
struct LockParam {
    address proxyCollection;
    address collection;
    uint256[] nftIds;
    uint256 expiryTs;
    uint8 vipLevel;
    uint256 maxCreditCost;
    address creditToken;
}
