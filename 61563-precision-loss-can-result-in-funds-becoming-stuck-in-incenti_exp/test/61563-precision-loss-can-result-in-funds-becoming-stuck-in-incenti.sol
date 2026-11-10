// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

/*  Paladin Valkyrie — rate = amount / duration strands the remainder
    (Cyfrin / Draiakoo, finding #61563, 12 March 2025).

    SYNTHETIC, cheatcode-free. `nowTs` stands in for `block.timestamp`.
    11,235,955 base units (the report's $10,000 of 8-decimal WBTC) streamed
    over 10 weeks stores a rate of 1 unit per second. The sole staker can
    claim 6,048,000. N = 5,187,955 stays in the logic forever.
    Control adds that remainder to the final claim and pays the full deposit. */

contract Token {
    string public name;
    string public symbol;
    uint8 public decimals;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    constructor(string memory _name, string memory _symbol, uint8 _decimals) {
        name = _name;
        symbol = _symbol;
        decimals = _decimals;
    }

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply += amount;
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
        require(balanceOf[from] >= amount, "bal");
        require(allowance[from][msg.sender] >= amount, "allow");
        allowance[from][msg.sender] -= amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

contract Logic {
    Token public reward;
    uint256 public nowTs;
    uint256 public totalLiquidity;
    uint256 public ratePerSec;
    uint256 public endTimestamp;
    uint256 public lastUpdateTime;
    uint256 public funded;

    constructor(Token _reward) {
        reward = _reward;
        nowTs = 1_700_000_000;
    }

    function advance(uint256 dt) external {
        nowTs += dt;
    }

    function stake(uint256 amount) external {
        totalLiquidity += amount;
    }

    function depositRewards(uint256 amount, uint256 duration) external {
        require(duration > 0 && amount > 0, "amount");
        require(totalLiquidity > 0, "liquidity");
        uint256 rate = amount / duration;
        // @> VULN: amount / duration drops the remainder, and nothing ever pays it
        // FIX: on the final claim, also transfer amount - rate * duration
        ratePerSec = rate;
        endTimestamp = nowTs + duration;
        lastUpdateTime = nowTs;
        funded = amount;
        reward.transferFrom(msg.sender, address(this), amount);
    }

    function claim() external returns (uint256 paid) {
        require(totalLiquidity > 0, "liquidity");
        uint256 applicable = nowTs < endTimestamp ? nowTs : endTimestamp;
        uint256 dt = applicable - lastUpdateTime;
        paid = dt * ratePerSec;
        if (paid != 0) {
            reward.transfer(msg.sender, paid);
            lastUpdateTime = applicable;
            ratePerSec = 0;
        }
    }
}

contract Exploit {
    // 10000e8 / 89000, the report's $10,000 WBTC deposit. 10 weeks = 6,048,000 seconds.
    uint256 public constant AMOUNT = 11_235_955;
    uint256 public constant DURATION = 10 weeks;
    uint256 public constant PAID = 6_048_000;
    uint256 public constant STUCK = 5_187_955;

    Token public reward;
    Logic public logic;
    uint256 public paid;
    uint256 public stuck;

    constructor() {
        reward = new Token("Wrapped BTC", "WBTC", 8); // nonce 1
        logic = new Logic(reward); // nonce 2
    }

    function run() external {
        logic.stake(1 ether);
        reward.mint(address(this), AMOUNT);
        reward.approve(address(logic), AMOUNT);
        logic.depositRewards(AMOUNT, DURATION);
        logic.advance(DURATION);
        paid = logic.claim();
        stuck = reward.balanceOf(address(logic));
        require(paid == PAID, "streamed amount");
        require(paid < AMOUNT, "claim was not short");
        require(stuck == STUCK, "remainder not stuck");
    }
}

/// @dev Control: once the window has elapsed, the final claim also pays the remainder.
contract LogicFixed {
    Token public reward;
    uint256 public nowTs;
    uint256 public totalLiquidity;
    uint256 public ratePerSec;
    uint256 public endTimestamp;
    uint256 public lastUpdateTime;

    constructor(Token _reward) {
        reward = _reward;
        nowTs = 1_700_000_000;
    }

    function advance(uint256 dt) external {
        nowTs += dt;
    }

    function stake(uint256 amount) external {
        totalLiquidity += amount;
    }

    function depositRewards(uint256 amount, uint256 duration) external {
        require(duration > 0 && amount > 0, "amount");
        require(totalLiquidity > 0, "liquidity");
        uint256 rate = amount / duration;
        ratePerSec = rate;
        endTimestamp = nowTs + duration;
        lastUpdateTime = nowTs;
        reward.transferFrom(msg.sender, address(this), amount);
    }

    function claim() external returns (uint256 paid) {
        require(totalLiquidity > 0, "liquidity");
        uint256 applicable = nowTs < endTimestamp ? nowTs : endTimestamp;
        uint256 dt = applicable - lastUpdateTime;
        paid = dt * ratePerSec;
        if (nowTs >= endTimestamp) {
            uint256 dust = reward.balanceOf(address(this)) - paid;
            paid += dust;
        }
        if (paid != 0) {
            reward.transfer(msg.sender, paid);
            lastUpdateTime = applicable;
            ratePerSec = 0;
        }
    }
}
