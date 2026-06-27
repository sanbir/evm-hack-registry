// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import "./interface/IFlooring.sol";
import "./Constants.sol";
import {
    TicketRecord,
    SafeBoxKey,
    SafeBox,
    FeeConfig,
    RoyaltyFeeRate,
    SafeboxFeeRate,
    VaultFeeRate,
    Fees,
    AuctionType
} from "./logic/Structs.sol";

contract FlooringGetter {
    IFlooring public immutable _flooring;

    uint256 constant COLLECTION_STATES_SLOT = 101;
    uint256 constant USER_ACCOUNTS_SLOT = 102;
    uint256 constant SUPPORTED_TOKENS_SLOT = 103;
    uint256 constant COLLECTION_PROXY_SLOT = 104;
    uint256 constant COLLECTION_FEES_SLOT = 105;

    uint256 constant MASK_32 = (1 << 32) - 1;
    uint256 constant MASK_48 = (1 << 48) - 1;
    uint256 constant MASK_64 = (1 << 64) - 1;
    uint256 constant MASK_96 = (1 << 96) - 1;
    uint256 constant MASK_128 = (1 << 128) - 1;
    uint256 constant MASK_160 = (1 << 160) - 1;

    constructor(address flooring) {
        _flooring = IFlooring(flooring);
    }

    function supportedToken(address token) public view returns (bool) {
        uint256 val = uint256(_flooring.extsload(keccak256(abi.encode(token, SUPPORTED_TOKENS_SLOT))));

        return val != 0;
    }

    function collectionProxy(address proxy) public view returns (address) {
        address underlying =
            address(uint160(uint256(_flooring.extsload(keccak256(abi.encode(proxy, COLLECTION_PROXY_SLOT))))));
        return underlying;
    }

    function collectionFee(address collection, address token) public view returns (FeeConfig memory fee) {
        bytes memory values =
            _flooring.extsload(keccak256(abi.encode(token, keccak256(abi.encode(collection, COLLECTION_FEES_SLOT)))), 3);
        uint256 slot1;
        uint256 slot2;
        uint256 slot3;
        assembly {
            slot1 := mload(add(values, 0x20))
            slot2 := mload(add(values, 0x40))
            slot3 := mload(add(values, 0x60))
        }
        fee = FeeConfig({
            royalty: RoyaltyFeeRate({
                receipt: address(uint160(slot1 & MASK_160)),
                marketlist: uint16((slot1 >> 160) & 0xFFFF),
                vault: uint16((slot1 >> 176) & 0xFFFF),
                raffle: uint16((slot1 >> 192) & 0xFFFF)
            }),
            safeboxFee: SafeboxFeeRate({
                receipt: address(uint160(slot2 & MASK_160)),
                auctionOwned: uint16((slot2 >> 160) & 0xFFFF),
                auctionExpired: uint16((slot2 >> 176) & 0xFFFF),
                raffle: uint16((slot2 >> 192) & 0xFFFF),
                marketlist: uint16((slot2 >> 208) & 0xFFFF)
            }),
            vaultFee: VaultFeeRate({
                receipt: address(uint160(slot3 & MASK_160)),
                vaultAuction: uint16((slot3 >> 160) & 0xFFFFF),
                redemptionBase: uint16((slot3 >> 176) & 0xFFFFF)
            })
        });
    }

    function fragmentTokenOf(address collection) public view returns (address token) {
        bytes32 val = _flooring.extsload(keccak256(abi.encode(collection, COLLECTION_STATES_SLOT)));
        assembly {
            token := val
        }
    }

    function collectionInfo(address collection)
        public
        view
        returns (
            address fragmentToken,
            uint256 freeNftLength,
            uint64 lastUpdatedBucket,
            uint64 nextKeyId,
            uint64 activeSafeBoxCnt,
            uint64 infiniteCnt,
            uint64 nextActivityId,
            uint32 lastVaultAuctionPeriodTs
        )
    {
        bytes memory val = _flooring.extsload(keccak256(abi.encode(collection, COLLECTION_STATES_SLOT)), 9);

        assembly {
            fragmentToken := mload(add(val, 0x20))
            freeNftLength := mload(add(val, mul(3, 0x20)))

            let cntVal := mload(add(val, mul(8, 0x20)))
            lastUpdatedBucket := and(cntVal, MASK_64)
            nextKeyId := and(shr(64, cntVal), MASK_64)
            activeSafeBoxCnt := and(shr(128, cntVal), MASK_64)
            infiniteCnt := and(shr(192, cntVal), MASK_64)

            cntVal := mload(add(val, mul(9, 0x20)))
            nextActivityId := and(cntVal, MASK_64)
            lastVaultAuctionPeriodTs := and(shr(64, cntVal), MASK_32)
        }
    }

    function getFreeNftIds(address collection, uint256 startIdx, uint256 size)
        public
        view
        returns (uint256[] memory nftIds)
    {
        bytes32 collectionSlot = keccak256(abi.encode(collection, COLLECTION_STATES_SLOT));
        bytes32 nftIdsSlot = bytes32(uint256(collectionSlot) + 2);
        uint256 freeNftLength = uint256(_flooring.extsload(nftIdsSlot));

        if (startIdx >= freeNftLength || size == 0) {
            return nftIds;
        }

        uint256 maxLen = freeNftLength - startIdx;
        if (size < maxLen) {
            maxLen = size;
        }

        bytes memory arrVal = _flooring.extsload(bytes32(uint256(keccak256(abi.encode(nftIdsSlot))) + startIdx), maxLen);

        nftIds = new uint256[](maxLen);
        assembly {
            for {
                let i := 0x20
                let end := mul(add(1, maxLen), 0x20)
            } lt(i, end) { i := add(i, 0x20) } { mstore(add(nftIds, i), mload(add(arrVal, i))) }
        }
    }

    function getSafeBox(address collection, uint256 nftId) public view returns (SafeBox memory safeBox) {
        bytes32 collectionSlot = keccak256(abi.encode(underlyingCollection(collection), COLLECTION_STATES_SLOT));
        bytes32 safeBoxMapSlot = bytes32(uint256(collectionSlot) + 3);

        uint256 val = uint256(_flooring.extsload(keccak256(abi.encode(nftId, safeBoxMapSlot))));

        safeBox.keyId = uint64(val & MASK_64);
        safeBox.expiryTs = uint32(val >> 64);
        safeBox.owner = address(uint160(val >> 96));
    }

    function getAuction(address collection, uint256 nftId)
        public
        view
        returns (
            uint96 endTime,
            address bidToken,
            uint128 minimumBid,
            uint128 lastBidAmount,
            address lastBidder,
            address triggerAddress,
            uint64 activityId,
            AuctionType typ,
            Fees memory fees
        )
    {
        bytes32 collectionSlot = keccak256(abi.encode(underlyingCollection(collection), COLLECTION_STATES_SLOT));
        bytes32 auctionMapSlot = bytes32(uint256(collectionSlot) + 4);

        bytes memory val = _flooring.extsload(keccak256(abi.encode(nftId, auctionMapSlot)), 6);

        uint256 royaltyRate;
        uint256 protocolRate;
        assembly {
            let slotVal := mload(add(val, 0x20))
            endTime := and(slotVal, MASK_96)
            bidToken := shr(96, slotVal)

            slotVal := mload(add(val, 0x40))
            minimumBid := and(slotVal, MASK_96)
            triggerAddress := shr(96, slotVal)

            slotVal := mload(add(val, 0x60))
            lastBidAmount := and(slotVal, MASK_96)
            lastBidder := shr(96, slotVal)

            slotVal := mload(add(val, 0x80))
            activityId := and(shr(8, slotVal), MASK_64)
            typ := and(shr(104, slotVal), 0xFF)

            royaltyRate := mload(add(val, 0xA0))
            protocolRate := mload(add(val, 0xC0))
        }
        fees = parseFees(royaltyRate, protocolRate);
    }

    function getRaffle(address collection, uint256 nftId)
        public
        view
        returns (
            uint48 endTime,
            uint48 maxTickets,
            address token,
            uint96 ticketPrice,
            uint96 collectedFund,
            uint64 activityId,
            address owner,
            uint48 ticketSold,
            bool isSettling,
            uint256 ticketsArrLen,
            Fees memory fees
        )
    {
        bytes32 raffleMapSlot =
            bytes32(uint256(keccak256(abi.encode(underlyingCollection(collection), COLLECTION_STATES_SLOT))) + 5);

        bytes memory val = _flooring.extsload(keccak256(abi.encode(nftId, raffleMapSlot)), 6);

        uint256 royaltyRate;
        uint256 protocolRate;
        assembly {
            let slotVal := mload(add(val, 0x20))
            endTime := and(slotVal, MASK_48)
            maxTickets := and(shr(48, slotVal), MASK_48)
            token := and(shr(96, slotVal), MASK_160)

            slotVal := mload(add(val, 0x40))
            owner := and(slotVal, MASK_160)
            ticketPrice := and(shr(160, slotVal), MASK_96)

            slotVal := mload(add(val, 0x60))
            activityId := and(slotVal, MASK_64)
            collectedFund := and(shr(64, slotVal), MASK_96)
            ticketSold := and(shr(160, slotVal), MASK_48)
            isSettling := and(shr(208, slotVal), 0xFF)

            ticketsArrLen := mload(add(val, 0x80))

            royaltyRate := mload(add(val, 0xA0))
            protocolRate := mload(add(val, 0xC0))
        }
        fees = parseFees(royaltyRate, protocolRate);
    }

    function getRaffleTicketRecords(address collection, uint256 nftId, uint256 startIdx, uint256 size)
        public
        view
        returns (TicketRecord[] memory tickets)
    {
        bytes32 collectionSlot = keccak256(abi.encode(underlyingCollection(collection), COLLECTION_STATES_SLOT));
        bytes32 raffleMapSlot = bytes32(uint256(collectionSlot) + 5);
        bytes32 ticketRecordsSlot = bytes32(uint256(keccak256(abi.encode(nftId, raffleMapSlot))) + 3);
        uint256 totalRecordsLen = uint256(_flooring.extsload(ticketRecordsSlot));

        if (startIdx >= totalRecordsLen || size == 0) {
            return tickets;
        }

        uint256 maxLen = totalRecordsLen - startIdx;
        if (size < maxLen) {
            maxLen = size;
        }

        bytes memory arrVal =
            _flooring.extsload(bytes32(uint256(keccak256(abi.encode(ticketRecordsSlot))) + startIdx), maxLen);

        tickets = new TicketRecord[](maxLen);
        for (uint256 i; i < maxLen; ++i) {
            uint256 element;
            assembly {
                element := mload(add(arrVal, mul(add(i, 1), 0x20)))
            }
            tickets[i].buyer = address(uint160(element & MASK_160));
            tickets[i].startIdx = uint48((element >> 160) & MASK_48);
            tickets[i].endIdx = uint48((element >> 208) & MASK_48);
        }
    }

    function getPrivateOffer(address collection, uint256 nftId)
        public
        view
        returns (
            uint96 endTime,
            address token,
            uint96 price,
            address owner,
            address buyer,
            uint64 activityId,
            Fees memory fees
        )
    {
        bytes32 collectionSlot = keccak256(abi.encode(underlyingCollection(collection), COLLECTION_STATES_SLOT));
        bytes32 offerMapSlot = bytes32(uint256(collectionSlot) + 6);

        bytes memory val = _flooring.extsload(keccak256(abi.encode(nftId, offerMapSlot)), 5);

        uint256 royaltyRate;
        uint256 protocolRate;
        assembly {
            let slotVal := mload(add(val, 0x20))
            endTime := and(slotVal, MASK_96)
            token := and(shr(96, slotVal), MASK_160)

            slotVal := mload(add(val, 0x40))
            price := and(slotVal, MASK_96)
            owner := and(shr(96, slotVal), MASK_160)

            slotVal := mload(add(val, 0x60))
            buyer := and(slotVal, MASK_160)
            activityId := and(shr(160, slotVal), MASK_64)

            royaltyRate := mload(add(val, 0x80))
            protocolRate := mload(add(val, 0xA0))
        }
        fees = parseFees(royaltyRate, protocolRate);
    }

    function tokenBalance(address user, address token) public view returns (uint256) {
        bytes32 userSlot = keccak256(abi.encode(user, USER_ACCOUNTS_SLOT));
        bytes32 tokenMapSlot = bytes32(uint256(userSlot) + 4);

        bytes32 balance = _flooring.extsload(keccak256(abi.encode(token, tokenMapSlot)));

        return uint256(balance);
    }

    function userAccount(address user)
        public
        view
        returns (
            uint256 minMaintCredit,
            address firstCollection,
            uint8 minMaintVipLevel,
            uint256[] memory vipKeyCnts,
            uint256 lockedCredit,
            uint32 lastQuotaPeriodTs,
            uint16 safeboxQuotaUsed
        )
    {
        bytes32 userSlot = keccak256(abi.encode(user, USER_ACCOUNTS_SLOT));

        bytes memory val = _flooring.extsload(userSlot, 6);

        uint256 vipInfo;
        assembly {
            let slotVal := mload(add(val, 0x20))
            minMaintCredit := and(slotVal, MASK_96)
            firstCollection := and(shr(96, slotVal), MASK_160)

            vipInfo := mload(add(val, 0x40))
            lockedCredit := mload(add(val, 0x60))

            slotVal := mload(add(val, 0xC0))
            lastQuotaPeriodTs := and(slotVal, MASK_32)
            safeboxQuotaUsed := and(shr(32, slotVal), 0xFFFF)
        }

        vipKeyCnts = new uint256[](Constants.VIP_LEVEL_COUNT);
        minMaintVipLevel = uint8((vipInfo >> 240) & 0xFF);
        for (uint256 i; i < Constants.VIP_LEVEL_COUNT; ++i) {
            vipKeyCnts[i] = (vipInfo >> (i * 24)) & 0xFFFFFF;
        }
    }

    function userCollection(address user, address collection, uint256 nftId)
        public
        view
        returns (
            uint256 totalLockingCredit,
            address next,
            uint32 keyCnt,
            uint32 vaultContQuota,
            uint32 lastVaultActiveTs,
            SafeBoxKey memory key
        )
    {
        bytes32 userSlot = keccak256(abi.encode(user, USER_ACCOUNTS_SLOT));
        bytes32 collectionSlot = keccak256(abi.encode(underlyingCollection(collection), bytes32(uint256(userSlot) + 3)));
        bytes32 collectionKeysSlot = keccak256(abi.encode(nftId, collectionSlot));

        bytes memory vals = _flooring.extsload(bytes32(uint256(collectionSlot) + 1), 2);
        assembly {
            let slotVal := mload(add(vals, 0x20))
            totalLockingCredit := and(slotVal, MASK_96)
            next := and(shr(96, slotVal), MASK_160)

            slotVal := mload(add(vals, 0x40))
            keyCnt := and(slotVal, MASK_32)
            vaultContQuota := and(shr(32, slotVal), MASK_32)
            lastVaultActiveTs := and(shr(64, slotVal), MASK_32)
        }

        {
            uint256 val = uint256(_flooring.extsload(collectionKeysSlot));
            key.lockingCredit = uint96(val & MASK_96);
            key.keyId = uint64((val >> 96) & MASK_64);
            key.vipLevel = uint8((val >> 160) & 0xFF);
        }
    }

    function underlyingCollection(address collection) private view returns (address) {
        address underlying = collectionProxy(collection);
        if (underlying == address(0)) {
            return collection;
        }
        return underlying;
    }

    function parseFees(uint256 royalty, uint256 protocol) private pure returns (Fees memory fees) {
        fees.royalty.receipt = address(uint160(royalty & MASK_160));
        fees.royalty.rateBips = uint16(royalty >> 160);

        fees.protocol.receipt = address(uint160(protocol & MASK_160));
        fees.protocol.rateBips = uint16(protocol >> 160);
    }
}
