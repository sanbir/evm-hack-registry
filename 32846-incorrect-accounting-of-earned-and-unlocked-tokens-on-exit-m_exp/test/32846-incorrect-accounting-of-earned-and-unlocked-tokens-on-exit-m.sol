// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// Radiant MultiFeeDistribution.exit deletes earnings and reduces total, but leaves unlocked and earned.
/// The user is paid 100 RDNT. The remaining 50 RDNT lock cannot be withdrawn: the next total update underflows.

contract Rdnt {
    mapping(address => uint256) public balanceOf;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function transfer(address to, uint256 amount) external {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
    }
}

contract MultiFeeDistribution {
    struct Earned {
        uint256 amount;
        uint256 unlockTime;
    }

    struct Balances {
        uint256 total;
        uint256 unlocked;
        uint256 earned;
        uint256 locked;
    }

    Rdnt public stakingToken;
    mapping(address => Balances) public balances;
    mapping(address => Earned[]) public userEarnings;

    constructor(Rdnt token) {
        stakingToken = token;
    }

    function seed(address user, uint256 unlockedAmt, uint256 earnedAmt, uint256 lockedAmt) external {
        Balances storage bal = balances[user];
        bal.unlocked = unlockedAmt;
        bal.earned = earnedAmt;
        bal.locked = lockedAmt;
        bal.total = unlockedAmt + earnedAmt + lockedAmt;
        if (earnedAmt > 0) userEarnings[user].push(Earned({amount: earnedAmt, unlockTime: 0}));
        stakingToken.mint(address(this), bal.total);
    }

    function withdrawableBalance(address user)
        public
        view
        returns (uint256 amount, uint256 penaltyAmount, uint256 burnAmount)
    {
        uint256 earned = balances[user].earned;
        uint256 vested;
        uint256 length = userEarnings[user].length;
        for (uint256 i; i < length; i++) {
            if (userEarnings[user][i].unlockTime <= block.timestamp) vested += userEarnings[user][i].amount;
        }
        uint256 still = earned - vested;
        penaltyAmount = still / 2;
        burnAmount = still - penaltyAmount;
        amount = balances[user].unlocked + earned - penaltyAmount - burnAmount;
    }

    function exit(bool claimRewards) external {
        address onBehalfOf = msg.sender;
        (uint256 amount, uint256 penaltyAmount, uint256 burnAmount) = withdrawableBalance(onBehalfOf);
        delete userEarnings[onBehalfOf];
        Balances storage bal = balances[onBehalfOf];
        // @> VULN: total is reduced but unlocked and earned are left unchanged
        bal.total = bal.total - amount - penaltyAmount;
        _withdrawTokens(onBehalfOf, amount, penaltyAmount, burnAmount, claimRewards);
    }

    function exitFixed(bool claimRewards) external {
        address onBehalfOf = msg.sender;
        (uint256 amount, uint256 penaltyAmount, uint256 burnAmount) = withdrawableBalance(onBehalfOf);
        delete userEarnings[onBehalfOf];
        Balances storage bal = balances[onBehalfOf];
        bal.total = bal.total - bal.unlocked - bal.earned;
        bal.unlocked = 0;
        bal.earned = 0;
        _withdrawTokens(onBehalfOf, amount, penaltyAmount, burnAmount, claimRewards);
    }

    function withdrawLock() external {
        Balances storage bal = balances[msg.sender];
        (uint256 amount, uint256 penaltyAmount,) = withdrawableBalance(msg.sender);
        uint256 locked = bal.locked;
        bal.total = bal.total - locked - amount - penaltyAmount;
        bal.locked = 0;
        stakingToken.transfer(msg.sender, locked);
    }

    function _withdrawTokens(address to, uint256 amount, uint256 penaltyAmount, uint256 burnAmount, bool claimRewards)
        internal
    {
        claimRewards;
        penaltyAmount;
        burnAmount;
        if (amount > 0) stakingToken.transfer(to, amount);
    }
}

contract Exploit {
    Rdnt public token;
    MultiFeeDistribution public mfd;
    uint256 public paid;
    uint256 public frozen;
    bool public lockReverted;
    uint256 public staleUnlocked;
    uint256 public staleEarned;

    constructor() {
        token = new Rdnt();
        mfd = new MultiFeeDistribution(token);
        mfd.seed(address(this), 40 ether, 60 ether, 50 ether);
    }

    function run() external {
        uint256 before = token.balanceOf(address(this));
        mfd.exit(false);
        paid = token.balanceOf(address(this)) - before;
        (bool ok,) = address(mfd).call(abi.encodeWithSelector(mfd.withdrawLock.selector));
        lockReverted = !ok;
        frozen = token.balanceOf(address(mfd));
        (uint256 total, uint256 unlocked, uint256 earned, uint256 locked) = mfd.balances(address(this));
        total;
        locked;
        staleUnlocked = unlocked;
        staleEarned = earned;
        require(paid == 100 ether, "paid");
        require(lockReverted, "lock moved");
        require(frozen == 50 ether, "frozen");
        require(staleUnlocked == 40 ether, "unlocked");
        require(staleEarned == 60 ether, "earned");
    }

    function runControl() external {
        mfd.exitFixed(false);
        mfd.withdrawLock();
        require(token.balanceOf(address(this)) == 150 ether, "all out");
        require(token.balanceOf(address(mfd)) == 0, "none frozen");
    }
}
