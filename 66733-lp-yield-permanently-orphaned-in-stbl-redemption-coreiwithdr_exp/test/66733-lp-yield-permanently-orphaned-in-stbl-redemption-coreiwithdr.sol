// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*  STBL Ess — LP yield orphaned in STBL_Redemption_Core::iWithdraw
    (Cyfrin, 2026-06). iWithdraw updates the stale rewardIndex and then
    spliter.split burns NFTID without iClaimYield. disableYield snapshots
    the pending yield onto the burned id. The LP harvest pays 0.
    The control claims first and pays the LP the full 500 yield.
*/

contract YieldToken {
    string public symbol = "YLD";
    uint8 public constant decimals = 18;
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

contract YieldDistributor {
    YieldToken public token;
    mapping(uint256 => uint256) public pending;
    mapping(uint256 => uint256) public earned;
    mapping(uint256 => bool) public alive;

    constructor(YieldToken _token) {
        token = _token;
    }

    function enable(uint256 id) external {
        alive[id] = true;
    }

    function accrue(uint256 id, uint256 amount) external {
        token.mint(address(this), amount);
        pending[id] += amount;
    }

    function claim(uint256 id) external returns (uint256 amt) {
        require(alive[id], "ownerOf");
        amt = pending[id];
        pending[id] = 0;
        if (amt > 0) {
            token.transfer(msg.sender, amt);
        }
    }

    function disableYield(uint256 id) external {
        earned[id] += pending[id];
        pending[id] = 0;
        alive[id] = false;
    }
}

contract Splitter {
    YieldDistributor public dist;
    uint256 public nextId;

    constructor(YieldDistributor _dist) {
        dist = _dist;
        nextId = 10;
    }

    function split(uint256 oldId, uint256) external returns (uint256 tokenIdA, uint256 tokenIdB) {
        dist.disableYield(oldId);
        tokenIdA = ++nextId;
        tokenIdB = ++nextId;
        dist.enable(tokenIdA);
        dist.enable(tokenIdB);
    }
}

contract RedemptionCore {
    struct User {
        uint256 stableValueNet;
        uint256 rewardIndex;
        uint256 earned;
    }

    mapping(address => User) public userData;
    uint256 public rewardIndex;
    uint256 public totalSupply;
    uint256 public NFTID;
    YieldDistributor public dist;
    Splitter public spliter;
    YieldToken public token;

    constructor(YieldToken _token, YieldDistributor _dist, Splitter _spliter) {
        token = _token;
        dist = _dist;
        spliter = _spliter;
    }

    function seed(address lp, uint256 shares, uint256 nftId) external {
        NFTID = nftId;
        dist.enable(nftId);
        userData[lp].stableValueNet = shares;
        totalSupply = shares;
    }

    function withdraw(uint256 amt) external {
        iWithdraw(amt);
    }

    function iClaimYield() public returns (uint256 y) {
        y = dist.claim(NFTID);
        if (totalSupply > 0 && y > 0) {
            rewardIndex += (y * 1e18) / totalSupply;
        }
    }

    function _updateRewards(address user) internal {
        User storage u = userData[user];
        if (u.stableValueNet > 0 && rewardIndex > u.rewardIndex) {
            u.earned += (u.stableValueNet * (rewardIndex - u.rewardIndex)) / 1e18;
        }
        u.rewardIndex = rewardIndex;
    }

    function iWithdraw(uint256 _amt) internal {
        _updateRewards(msg.sender);
        // @> VULN: iWithdraw splits the pool NFT before iClaimYield, so pending yield is snapshotted onto a burned id
        (uint256 tokenIdA,) = spliter.split(NFTID, _amt);
        NFTID = tokenIdA;
        userData[msg.sender].stableValueNet -= _amt;
        totalSupply -= _amt;
    }

    function harvest(address user) external returns (uint256 paid) {
        _updateRewards(user);
        paid = userData[user].earned;
        userData[user].earned = 0;
        if (paid > 0) {
            token.transfer(user, paid);
        }
    }
}

contract RedemptionCoreFixed {
    struct User {
        uint256 stableValueNet;
        uint256 rewardIndex;
        uint256 earned;
    }

    mapping(address => User) public userData;
    uint256 public rewardIndex;
    uint256 public totalSupply;
    uint256 public NFTID;
    YieldDistributor public dist;
    Splitter public spliter;
    YieldToken public token;

    constructor(YieldToken _token, YieldDistributor _dist, Splitter _spliter) {
        token = _token;
        dist = _dist;
        spliter = _spliter;
    }

    function seed(address lp, uint256 shares, uint256 nftId) external {
        NFTID = nftId;
        dist.enable(nftId);
        userData[lp].stableValueNet = shares;
        totalSupply = shares;
    }

    function withdraw(uint256 amt) external {
        iWithdraw(amt);
    }

    function iClaimYield() public returns (uint256 y) {
        y = dist.claim(NFTID);
        if (totalSupply > 0 && y > 0) {
            rewardIndex += (y * 1e18) / totalSupply;
        }
    }

    function _updateRewards(address user) internal {
        User storage u = userData[user];
        if (u.stableValueNet > 0 && rewardIndex > u.rewardIndex) {
            u.earned += (u.stableValueNet * (rewardIndex - u.rewardIndex)) / 1e18;
        }
        u.rewardIndex = rewardIndex;
    }

    function iWithdraw(uint256 _amt) internal {
        iClaimYield();
        _updateRewards(msg.sender);
        (uint256 tokenIdA,) = spliter.split(NFTID, _amt);
        NFTID = tokenIdA;
        userData[msg.sender].stableValueNet -= _amt;
        totalSupply -= _amt;
    }

    function harvest(address user) external returns (uint256 paid) {
        _updateRewards(user);
        paid = userData[user].earned;
        userData[user].earned = 0;
        if (paid > 0) {
            token.transfer(user, paid);
        }
    }
}

contract Exploit {
    uint256 public constant SHARES = 10000 ether;
    uint256 public constant WITHDRAW = 1000 ether;
    uint256 public constant YIELD = 500 ether;

    YieldToken public token;
    YieldDistributor public dist;
    Splitter public spliter;
    RedemptionCore public core;
    uint256 public oldNft;
    uint256 public lpPaid;
    bool public oldClaimable;

    constructor() {
        token = new YieldToken();
        dist = new YieldDistributor(token);
        spliter = new Splitter(dist);
        core = new RedemptionCore(token, dist, spliter);
        core.seed(address(this), SHARES, 1);
    }

    function run() external {
        oldNft = core.NFTID();
        dist.accrue(oldNft, YIELD);
        uint256 pendingBefore = dist.pending(oldNft);
        core.withdraw(WITHDRAW);
        uint256 stranded = dist.earned(oldNft);
        uint256 pulled = core.iClaimYield();
        lpPaid = core.harvest(address(this));
        try dist.claim(oldNft) returns (uint256) {
            oldClaimable = true;
        } catch {
            oldClaimable = false;
        }
        require(pendingBefore == YIELD, "accrued");
        require(stranded == YIELD, "stranded");
        require(pulled == 0, "pulled");
        require(lpPaid == 0, "paid");
        require(!oldClaimable, "claimable");
        require(token.balanceOf(address(dist)) == YIELD, "locked");
        require(core.totalSupply() == SHARES - WITHDRAW, "supply");
        require(core.NFTID() != oldNft, "nft");
    }
}
