// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

/*  Paladin Valkyrie — rewardPerTokenStored uint96 downcast (Cyfrin, finding 61553)
    SYNTHETIC, cheatcode-free reduction for the EVM Playground.
    Root cause: _newRewardPerToken scales by 1e18 and divides by 6-decimal
    liquidity. The result does not fit in uint96, so _updateRewardState reverts
    and claim cannot pay. One second of the fixed block timestamp is enough:
    lastUpdateTime is 0 and endTimestamp is 1. 10 ether of rewards stay locked.
    A uint256 accumulator pays the same 10 ether. */

address constant LP = 0x2222222222222222222222222222222222222222;
uint256 constant UNIT = 1e18;
uint256 constant LIQUIDITY = 100_000_000;

library Cast {
    error Uint96Overflow(uint256 value);

    function toUint96(uint256 x) internal pure returns (uint96) {
        if (x > type(uint96).max) revert Uint96Overflow(x);
        return uint96(x);
    }
}

contract RewardToken {
    string public name = "RWD";
    string public symbol = "RWD";
    uint8 public decimals = 18;
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
        allowance[from][msg.sender] -= amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

contract IncentiveLogic {
    using Cast for uint256;

    struct RewardData {
        uint96 rewardPerTokenStored;
        uint256 ratePerSec;
        uint256 lastUpdateTime;
        uint256 endTimestamp;
    }

    RewardToken public token;
    uint256 public totalLiquidity;
    uint256 public userLiquidity;
    RewardData public reward;
    bool public updated;

    constructor(RewardToken t) {
        token = t;
    }

    function notifyLiquidity(uint256 liquidity) external {
        totalLiquidity = liquidity;
        userLiquidity = liquidity;
    }

    function depositRewards(uint256 amount, uint256 duration) external {
        token.transferFrom(msg.sender, address(this), amount);
        reward.ratePerSec = amount / duration;
        reward.lastUpdateTime = 0;
        reward.endTimestamp = duration;
    }

    function _newRewardPerToken() public view returns (uint256) {
        uint256 _totalSupply = totalLiquidity;
        RewardData memory _state = reward;
        if (_totalSupply == 0) return _state.rewardPerTokenStored;
        uint256 lastUpdateTimeApplicable = block.timestamp < _state.endTimestamp ? block.timestamp : _state.endTimestamp;
        return _state.rewardPerTokenStored
            + ((((lastUpdateTimeApplicable - _state.lastUpdateTime) * _state.ratePerSec) * UNIT) / _totalSupply);
    }

    function _updateRewardState() internal {
        // @> VULN: rewardPerTokenStored is downcast to uint96 and the scaled value overflows
        uint96 newRewardPerToken = _newRewardPerToken().toUint96();
        reward.rewardPerTokenStored = newRewardPerToken;
        updated = true;
    }

    function claim(address account) external returns (uint256 paid) {
        _updateRewardState();
        uint256 earned = (userLiquidity * (uint256(reward.rewardPerTokenStored))) / UNIT;
        token.transfer(account, earned);
        return earned;
    }
}

contract IncentiveLogicFixed {
    struct RewardData {
        uint256 rewardPerTokenStored;
        uint256 ratePerSec;
        uint256 lastUpdateTime;
        uint256 endTimestamp;
    }

    RewardToken public token;
    uint256 public totalLiquidity;
    uint256 public userLiquidity;
    RewardData public reward;

    constructor(RewardToken t) {
        token = t;
    }

    function notifyLiquidity(uint256 liquidity) external {
        totalLiquidity = liquidity;
        userLiquidity = liquidity;
    }

    function depositRewards(uint256 amount, uint256 duration) external {
        token.transferFrom(msg.sender, address(this), amount);
        reward.ratePerSec = amount / duration;
        reward.lastUpdateTime = 0;
        reward.endTimestamp = duration;
    }

    function _newRewardPerToken() public view returns (uint256) {
        uint256 _totalSupply = totalLiquidity;
        RewardData memory _state = reward;
        if (_totalSupply == 0) return _state.rewardPerTokenStored;
        uint256 lastUpdateTimeApplicable = block.timestamp < _state.endTimestamp ? block.timestamp : _state.endTimestamp;
        return _state.rewardPerTokenStored
            + ((((lastUpdateTimeApplicable - _state.lastUpdateTime) * _state.ratePerSec) * UNIT) / _totalSupply);
    }

    function claim(address account) external returns (uint256 paid) {
        uint256 newRewardPerToken = _newRewardPerToken();
        reward.rewardPerTokenStored = newRewardPerToken;
        paid = (userLiquidity * newRewardPerToken) / UNIT;
        token.transfer(account, paid);
    }
}

contract Exploit {
    uint256 public constant REWARDS = 10 ether;
    RewardToken public token;
    IncentiveLogic public logic;
    bool public claimReverted;
    uint256 public rawPerToken;
    uint256 public stuck;

    constructor() {
        token = new RewardToken();
        logic = new IncentiveLogic(token);
        token.mint(address(this), REWARDS);
    }

    function run() external {
        logic.notifyLiquidity(LIQUIDITY);
        token.approve(address(logic), REWARDS);
        logic.depositRewards(REWARDS, 1);
        rawPerToken = logic._newRewardPerToken();
        require(rawPerToken > type(uint96).max, "value fits in uint96");
        (bool ok,) = address(logic).call(abi.encodeWithSelector(logic.claim.selector, LP));
        claimReverted = ok == false;
        stuck = token.balanceOf(address(logic));
        require(claimReverted, "claim did not revert");
        require(stuck == REWARDS, "10 ether of rewards did not stay locked");
        require(token.balanceOf(LP) == 0, "LP was paid");
        require(logic.updated() == false, "downcast was stored");
    }
}
