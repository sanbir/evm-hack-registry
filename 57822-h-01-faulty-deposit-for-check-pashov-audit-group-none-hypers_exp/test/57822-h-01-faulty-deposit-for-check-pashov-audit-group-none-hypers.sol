// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*  Hyperstable vePeg.deposit_for — perpetual locks store end = 0
    (Pashov Audit Group, H-01, 19 March 2025, finding 57822).
    SYNTHETIC, cheatcode-free. One transaction, no warp.

    claim() routes a live or perpetual lock through deposit_for.
    deposit_for requires lock.end > block.timestamp. A perpetual
    lock has end = 0, so the require fails and the 100 ether reward
    is not added to that lock. The fixed check accepts
    perpetuallyLocked and credits the same lock with 100 ether. */

contract Reward {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        require(balanceOf[msg.sender] >= amount, "bal");
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        uint256 allowed = allowance[from][msg.sender];
        require(allowed >= amount, "allow");
        if (allowed != type(uint256).max) allowance[from][msg.sender] = allowed - amount;
        require(balanceOf[from] >= amount, "bal");
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

contract VePeg {
    struct LockedBalance {
        uint256 amount;
        uint256 end;
        bool perpetuallyLocked;
    }

    Reward public token;
    mapping(uint256 => LockedBalance) public locked;
    mapping(uint256 => address) public ownerOf;
    uint256 public perpetuallyLockedBalance;
    bool public allowPerpetual;

    constructor(Reward token_, bool allowPerpetual_) {
        token = token_;
        allowPerpetual = allowPerpetual_;
    }

    function createPerpetual(uint256 id, address owner, uint256 amount) external {
        locked[id] = LockedBalance(amount, 0, true);
        ownerOf[id] = owner;
    }

    function deposit_for(uint256 tokenId, uint256 value) external {
        LockedBalance memory _locked = locked[tokenId];
        // @> VULN: perpetual locks keep end at 0, so this require rejects the reward deposit.
        require(_locked.end > block.timestamp || (allowPerpetual && _locked.perpetuallyLocked), "Cannot add to expired lock. Withdraw");
        if (_locked.perpetuallyLocked) perpetuallyLockedBalance += value;
        locked[tokenId].amount = _locked.amount + value;
        require(token.transferFrom(msg.sender, address(this), value), "pull");
    }
}

contract Distributor {
    Reward public token;
    VePeg public ve;
    mapping(uint256 => uint256) public pending;

    constructor(Reward token_, VePeg ve_) {
        token = token_;
        ve = ve_;
    }

    function fund(uint256 id, uint256 amount) external {
        pending[id] += amount;
        require(token.transferFrom(msg.sender, address(this), amount), "fund");
    }

    function claim(uint256 tokenId) external returns (uint256 amount) {
        amount = pending[tokenId];
        if (amount != 0) {
            pending[tokenId] = 0;
            (uint256 end, bool perpetual) = _end(tokenId);
            if (end > block.timestamp || perpetual) {
                token.approve(address(ve), amount);
                ve.deposit_for(tokenId, amount);
            } else {
                require(token.transfer(ve.ownerOf(tokenId), amount), "owner");
            }
        }
    }

    function _end(uint256 tokenId) internal view returns (uint256 end, bool perpetual) {
        (uint256 amount, uint256 end_, bool perpetual_) = ve.locked(tokenId);
        amount;
        return (end_, perpetual_);
    }
}

contract Exploit {
    uint256 public constant LOCKED = 10 ether;
    uint256 public constant REWARD_AMT = 100 ether;
    uint256 public constant ID = 1;

    Reward public token; // nonce 1
    VePeg public ve; // nonce 2
    Distributor public dist; // nonce 3

    bool public claimReverted;
    uint256 public credited;
    uint256 public stillPending;
    uint256 public stuck;

    constructor() {
        token = new Reward();
        ve = new VePeg(token, false);
        dist = new Distributor(token, ve);
        ve.createPerpetual(ID, address(this), LOCKED);
        token.mint(address(this), REWARD_AMT);
    }

    function run() external {
        token.approve(address(dist), REWARD_AMT);
        dist.fund(ID, REWARD_AMT);
        uint256 beforeAmt = _amount();
        (bool ok,) = address(dist).call(abi.encodeWithSelector(dist.claim.selector, ID));
        claimReverted = !ok;
        credited = _amount() - beforeAmt;
        stillPending = dist.pending(ID);
        stuck = token.balanceOf(address(dist));
        require(claimReverted, "claim reverts");
        require(credited == 0, "lock credited 0, not 100");
        require(stillPending == REWARD_AMT, "reward still pending");
        require(stuck == REWARD_AMT, "100 stays in the distributor");
        require(ve.perpetuallyLockedBalance() == 0, "perpetual balance did not move");
    }

    function _amount() internal view returns (uint256 amount) {
        (amount,,) = ve.locked(ID);
    }
}
