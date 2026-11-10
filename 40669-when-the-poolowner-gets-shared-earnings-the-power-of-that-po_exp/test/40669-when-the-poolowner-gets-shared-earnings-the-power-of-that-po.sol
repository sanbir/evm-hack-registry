// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*  Goat Tech — shared earnings leave the pool owner's fs stale
    (Cantina / cccz, AuditVault 40669).
    SYNTHETIC, cheatcode-free. Report example:
      balance 100, maxEarning 200, fs = 100/200 = 0.5
      owner receives 50 shared earnings
      fs should become 150/200 = 0.75 and is left at 0.5
    fs is stored in hundredths (50 and 75). A pot of 200 pays
    200 * 50/100 = 100 on the stale fs. The fair payout is 150.
    The control calls reCalFs before the payout. */

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

contract EarningBook {
    uint256 public constant SCALE = 100;
    uint256 public constant POT = 200;

    Reward public reward;
    address public poolOwner;
    mapping(address => uint256) public balanceOf;
    mapping(address => uint256) public sharedA;
    mapping(address => uint256) public maxEarningOf;
    mapping(address => uint256) public fsOf;

    constructor(address poolOwner_) {
        poolOwner = poolOwner_;
        reward = new Reward();
    }

    function _reCalFs(address account_) internal {
        uint256 maxEarning = maxEarningOf[account_];
        uint256 earning = balanceOf[account_];
        fsOf[account_] = maxEarning == 0 ? 0 : earning * SCALE / maxEarning;
    }

    /// Fix: anyone can refresh fs after shared earnings land.
    function reCalFs(address account_) external {
        _reCalFs(account_);
    }

    function configure(address account, uint256 balance, uint256 shared, uint256 maxEarning) external {
        balanceOf[account] = balance;
        sharedA[account] = shared;
        maxEarningOf[account] = maxEarning;
        _reCalFs(account);
    }

    function getSponsorPart(address, uint256 amount) public view returns (address sponsor, uint256 sAmount) {
        sponsor = poolOwner;
        sAmount = amount;
    }

    function shareCommission(address account_) public {
        uint256 amount = balanceOf[account_] - sharedA[account_];
        if (amount == 0) {
            return;
        }
        address sponsor;
        uint256 sAmount;
        (sponsor, sAmount) = getSponsorPart(account_, amount);
        if (sAmount > 0) {
            _transfer(account_, sponsor, sAmount);
        }
        sharedA[account_] = balanceOf[account_];
        if (sharedA[account_] > maxEarningOf[account_]) {
            maxEarningOf[account_] = sharedA[account_];
        }
    }

    function _transfer(address from, address to, uint256 amount) internal {
        // @> VULN: shared earnings change balances here and fs is not recomputed.
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
    }

    function claim(address pool) external returns (uint256 paid) {
        paid = POT * fsOf[pool] / SCALE;
        reward.mint(pool, paid);
    }
}

contract Exploit {
    address public constant PAYER = address(0xB0B);

    EarningBook public book;
    Reward public reward;
    uint256 public staleFs;
    uint256 public fairFs;
    uint256 public staleReward;
    uint256 public fairReward;

    constructor() {
        book = new EarningBook(address(this));
        reward = book.reward();
    }

    function run() external {
        book.configure(address(this), 100, 100, 200);
        book.configure(PAYER, 50, 0, 200);
        require(book.fsOf(address(this)) == 50, "fs 0.5");
        book.shareCommission(PAYER);
        require(book.balanceOf(address(this)) == 150, "balance 150");
        staleFs = book.fsOf(address(this));
        fairFs = book.balanceOf(address(this)) * book.SCALE() / book.maxEarningOf(address(this));
        require(staleFs == 50, "fs stayed 0.5");
        require(fairFs == 75, "fs should be 0.75");
        staleReward = book.claim(address(this));
        fairReward = book.POT() * fairFs / book.SCALE();
        require(staleReward == 100, "paid on stale fs");
        require(fairReward == 150, "fair reward");
        require(staleReward != fairReward, "same payout");
        require(reward.balanceOf(address(this)) == staleReward, "reward token");
    }
}
